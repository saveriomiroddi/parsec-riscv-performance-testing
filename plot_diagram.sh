#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
shopt -s inherit_errexit

c_expected_header="threads,run,run_time"
c_debug_log_file=$(basename "$0").log
c_help='Usage: '"$(basename "$0")"' [-h|--help] [-s|--scale] [-o|--output diagram_file.ext] [-d|--dir] <input_files...>

Produces a diagram from the specified files, using gnuplot.

If --output is specified, the format is picked up from the diagram file extension (SVG/PNG).

The --scale option vertically scales, and superposes the lines, so that the shape can be directly compared.

The --dir option adds the directory name as prefix, in case the files have the same name.

Input files are expected to be csv, with the column/values produced by the benchmark script ('"$c_expected_header"'); the values for each group (threads,run) are averaged.'

c_line_colors_palette=(
  ff0000
  ffa500
  ffff00
  008000
  0000ff
  4b0082
  ee82ee
)

# User-defined
#
v_scale_lines=                 # boolean (blank/anything else)
v_output_file=                 # string
v_input_files=                 # array
v_add_dir_to_name=             # boolean

# Computed internally
#
v_image_format=  # string

####################################################################################################
# MAIN FUNCTIONS
####################################################################################################

function decode_cmdline_args {
  eval set -- "$(getopt --options hsdo: --long help,scale,dir,output: --name "$(basename "$0")" -- "$@")"

  while true ; do
    case "$1" in
      -h|--help)
        echo "$c_help"
        exit 0 ;;
      -s|--scale)
        v_scale_lines=1
        shift ;;
      -d|--dir)
        v_add_dir_to_name=1
        shift ;;
      -o|--output)
        v_output_file=$2
        shift 2 ;;
      --)
        shift
        break ;;
    esac
  done

  if [[ $# -lt 1 ]]; then
    echo "$c_help"
    exit 1
  fi

  if [[ -n $v_output_file ]]; then
    if [[ ! ${v_output_file,,} =~ (svg|png)$ ]]; then
      >&2 echo "Only SVG/PNG are supported!"
      exit 1
    else
      v_image_format=${BASH_REMATCH[1]}
    fi
  fi

  v_input_files=("$@")
}

function init_debug_log {
  exec 5> "$c_debug_log_file"
  BASH_XTRACEFD="5"
  set -x
}

function check_diagrams_header {
  for input_file in "${v_input_files[@]}"; do
    local actual_header
    actual_header=$(head -n 1 "$input_file")

    if [[ $actual_header != "$c_expected_header" ]]; then
      echo "The header of the file $(basename "$input_file") ($actual_header) is not as expected ($c_expected_header)."
      exit 1
    fi
  done
}

# Sample of generated commands:
#
#     set terminal svg background rgb 'white'
#     set output '/tmp/test.svg'
#
#     set datafile separator ','
#
#     set key noenhanced
#     set offsets graph 0.1, graph 0.1, graph 0.1, graph 0.1
#     set xlabel 'threads'
#     set ylabel 'time (s)'
#
#     plot \
#       '/tmp/tmp.MvmJDPpHXs' \
#          using 1:2:xtic(1) \
#          with linespoints title 'pigz_guest_basic', \
#       '/tmp/tmp.wXM5BzSJMg' \
#          using 1:2:xtic(1) \
#          with linespoints title 'pigz_host_basic' \
#
function generate_standard_diagram {
  local gnuplot_command

  if [[ -n $v_output_file ]]; then
    gnuplot_command+="\
set terminal $v_image_format background rgb 'white'
set output '$v_output_file'

"
  else
    gnuplot_command+="\
set terminal wxt size 1600,900

"
  fi

  # set key...: print titles exactly as they are
  # set offsets...: set margins
  #
  gnuplot_command+="\
set datafile separator ','

set key noenhanced
set offsets graph 0.1, graph 0.1, graph 0.1, graph 0.1
set xlabel 'threads'
set ylabel 'time (s)'

plot \\
"

  for ((i=0; i < ${#v_input_files[@]}; i++)); do
    if [[ $i -gt 0 ]]; then
      gnuplot_command+=", \\
"
    fi

    local input_file=${v_input_files[i]}

    local processed_input_file
    processed_input_file=$(mktemp)

    # Skip header, and compute average.
    #
    # shellcheck disable=SC2002
    cat "$input_file" | print_input_csv_averages > "$processed_input_file"

    local line_title

    if [[ -z $v_add_dir_to_name ]]; then
      line_title=$(echo "$input_file" | perl -ne 'print /([^\/]+)\.csv$/')
    else
      line_title=$(echo "$input_file" | perl -ne 'print /([^\/]*\/[^\/]+)\.csv$/')
    fi

    # 'using M:N': find data in columns M and N
    # 'xtic': print only the x tics for the line values
    #
    gnuplot_command+="\
'$processed_input_file' \\
  using 1:2:xtic(1) \\
  with linespoints title '$line_title' \\
"
  done

  if [[ -n $v_output_file ]]; then
    echo "$gnuplot_command" | gnuplot
    xdg-open "$v_output_file"
  else
    gnuplot_command+="
pause mouse close"

    echo "$gnuplot_command" | gnuplot
  fi
}

# Sample of generated command:
#
#     set terminal svg background rgb 'white'
#     set output 'test.svg'
#
#     set datafile separator ','
#
#     set key noenhanced
#     set offsets graph 0.1, graph 0.1, graph 0.1, graph 0.1
#     set xlabel 'threads'
#     set xrange[2:32]
#     set ylabel 'time'
#     unset ytics
#
#     set multiplot
#
#     set key at graph 1.0, .95
#     plot '/tmp/tmp.UNqNDZ6jYq' using 1:2:xtic(1) \
#       with linespoints linecolor rgb '#ff0000' title 'pigz_host_basic'
#
#     set key at graph 1.0, .90
#     plot '/tmp/tmp.Io0pbBdVmR' using 1:2:xtic(1) \
#       with linespoints linecolor rgb '#ffa500' title 'test'
#
#     unset multiplot
#
function generate_scaled_diagram {
  if [[ ${#v_input_files[@]} -gt ${#c_line_colors_palette[@]} ]]; then
    >&2 echo "No more than ${#c_line_colors_palette[@]} lines supported!"
    exit
  fi

  local gnuplot_command

  if [[ -n $v_output_file ]]; then
    gnuplot_command+="\
set terminal $v_image_format background rgb 'white'
set output '$v_output_file'

"
  else
    gnuplot_command+="\
set terminal wxt size 1600,900

"
  fi

  local all_thread_numbers
  mapfile -t all_thread_numbers < <(tail -q -n+2 "${v_input_files[@]}" | awk -F, '{ print $1 }' | sort -n)

  gnuplot_command+="\
set datafile separator ','

set key noenhanced
set offsets graph 0.1, graph 0.1, graph 0.1, graph 0.1
set xlabel 'threads'
"

  # We need to set the x range, because the diagrams may have different min/max values.
  #
  gnuplot_command+="\
set xrange[${all_thread_numbers[0]}:${all_thread_numbers[-1]}]
"

  gnuplot_command+="\
set ylabel 'time'
unset ytics

set multiplot
"

  local current_key_height=95

  for ((i=0; i < ${#v_input_files[@]}; i++)); do
    local input_file=${v_input_files[i]}

    local processed_input_file
    processed_input_file=$(mktemp)

    # shellcheck disable=SC2002
    cat "$input_file" | print_input_csv_averages > "$processed_input_file"

    local line_title
    line_title=$(echo "$input_file" | perl -ne 'print /([^\/]+)\.csv$/')

    gnuplot_command+="
set key at graph 1.0, .$current_key_height
plot '$processed_input_file' using 1:2:xtic(1) \\
  with linespoints linecolor rgb '#${c_line_colors_palette[i]}' title '$line_title'
"

    current_key_height=$((current_key_height - 5))
  done

  gnuplot_command+="
unset multiplot"

  if [[ -n $v_output_file ]]; then
    echo "$gnuplot_command" | gnuplot
    xdg-open "$v_output_file"
  else
    gnuplot_command+="
pause mouse close"

    echo "$gnuplot_command" | gnuplot
  fi
}

####################################################################################################
# HELPERS
####################################################################################################

function print_input_csv_averages {
  python3 -c "
import sys

all_run_times={}

next(sys.stdin)

for run_data in map(str.rstrip, sys.stdin):
  threads, _, run_time = run_data.split(',')
  threads_run_times = all_run_times.setdefault(int(threads), [])
  threads_run_times.append(float(run_time))

for threads, run_times in sorted(all_run_times.items()):
  print(f'{threads},{sum(run_times) / len(run_times)}')
"
}

####################################################################################################
# EXECUTION
####################################################################################################

decode_cmdline_args "$@"
init_debug_log

check_diagrams_header

if [[ -z $v_scale_lines ]]; then
  generate_standard_diagram
else
  generate_scaled_diagram
fi
