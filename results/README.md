# Results

This folder contains raw benchmark output files organized by environment.

## Structure

```
results/
├── native/          ← Bare-metal (no virtualization)
│   ├── cpu.txt
│   ├── memory.txt
│   ├── storage.txt
│   ├── redis.txt
│   └── mysql.txt
├── docker/          ← Docker container runs
│   ├── cpu.txt
│   ├── memory.txt
│   ├── storage_volume.txt      (Docker volume — optimal)
│   ├── storage_overlayfs.txt   (OverlayFS — default)
│   ├── redis_host_net.txt      (host networking — optimal)
│   ├── redis_nat.txt           (NAT networking — default)
│   ├── mysql_hostnet_volume.txt
│   └── mysql_nat_overlayfs.txt
└── kvm/             ← KVM virtual machine runs
    ├── cpu.txt
    ├── memory.txt
    ├── storage.txt
    ├── redis.txt
    └── mysql.txt
```

## File Format

Each `.txt` file is the **raw stdout** from the benchmark tool (sysbench, fio, redis-benchmark).  
Results are separated by `--- Threads: N ---` headers for multi-threaded sweeps.

## Parsing

Run `python3 scripts/benchmarks/plot_results.py` to parse these files automatically
and generate comparison charts in the `figures/` directory.
