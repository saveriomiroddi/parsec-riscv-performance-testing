c_input_type=simlarge

# With NTHREADS=1, on riscv crashes, on amd64 doesn't show ROI.
#
c_min_threads=2

# Input: $1=Number of threads.
#
function compose_benchmark_command {
  local threads=$1

  echo "
    cd parsec-benchmark &&
    HOSTTYPE=riscv64 bin/parsecmgmt -a run -p splash2x.volrend -i $c_input_type -n $threads
  "
}
