# Containers vs. Virtual Machines: Quantifying the Performance Gap in Modern Cloud Environments

**Seminar Report — Lovely Professional University**  
**Department of Computer Science & Engineering | Session 2025–2026**  
**Author:** Faisal Javid

---

## 📄 Overview

This repository accompanies the seminar report replicating and extending the seminal IBM Research study:

> Felter, W., Ferreira, A., Rajamony, R., & Rubio, J. (2015).  
> *An Updated Performance Comparison of Virtual Machines and Linux Containers.*  
> IBM Research Technical Report RC25482. IEEE ISPASS 2015.  
> [https://ieeexplore.ieee.org/document/7095802](https://ieeexplore.ieee.org/document/7095802)

The original study benchmarked Docker containers against KVM virtual machines on IBM server hardware in 2015. This project replicates those benchmarks on modern 2026 hardware (AMD Ryzen 9 5900HX / Zen 3) running CachyOS Linux with Kernel 6.19, quantifying how the "virtualization tax" has evolved over a decade.

---

## 🔬 What This Repo Contains

```
.
├── README.md                        ← You are here
├── report/
│   └── seminar_report.docx          ← Final formatted seminar report
├── figures/
│   └── figure_4_1_mysql_chart.png   ← MySQL throughput chart (Felter et al., 2015)
├── scripts/
│   ├── setup/
│   │   ├── 01_install_dependencies.sh   ← Install all benchmark tools on host
│   │   ├── 02_setup_docker.sh           ← Pull Docker images and configure containers
│   │   └── 03_setup_kvm.sh              ← Create and configure KVM virtual machine
│   └── benchmarks/
│       ├── 01_cpu_benchmark.sh          ← Sysbench CPU (native, Docker, KVM)
│       ├── 02_memory_benchmark.sh       ← STREAM memory bandwidth benchmark
│       ├── 03_storage_benchmark.sh      ← fio random read/write IOPS
│       ├── 04_redis_benchmark.sh        ← Redis-benchmark latency test
│       ├── 05_mysql_benchmark.sh        ← SysBench OLTP MySQL throughput
│       ├── run_all.sh                   ← Master script: runs all benchmarks
│       └── plot_results.py              ← Generates comparison charts from results
└── results/
    ├── native/                          ← Raw output files from bare-metal runs
    ├── docker/                          ← Raw output files from Docker runs
    └── kvm/                             ← Raw output files from KVM runs
```

---

## 🖥️ Test Environment

| Component        | This Study (2026)                          | Reference (Felter et al., 2015)             |
|------------------|--------------------------------------------|---------------------------------------------|
| CPU              | AMD Ryzen 9 5900HX (Zen 3, 8C/16T, 4.68 GHz) | 2× Intel Xeon E5-2665 (Sandy Bridge, 16C) |
| RAM              | 16 GB DDR4                                 | 256 GB DDR3                                 |
| Storage          | NVMe SSD                                   | IBM FlashSystem 840 (Enterprise All-Flash)  |
| Host OS          | CachyOS Linux (Kernel 6.19)                | Ubuntu 13.10 (Kernel 3.11.0)                |
| Hypervisor       | QEMU-KVM v10.2.0 (kvm_amd module)          | QEMU 1.5.0 / libvirt 1.1.1                  |
| Container Engine | Docker CE (latest)                         | Docker 1.0                                  |

---

## 🚀 Reproducing the Benchmarks

### Prerequisites

- A supported Linux host. The setup scripts now detect the distro automatically and install packages with the native package manager on Debian/Ubuntu, Fedora/RHEL-family, Arch-family, and openSUSE/SUSE systems.
- `sudo` / root access
- Internet connection (for package installation)
- KVM-capable CPU (check with: `egrep -c '(vmx|svm)' /proc/cpuinfo` — must be > 0)

### Step 1 — Install Dependencies

```bash
chmod +x scripts/setup/*.sh scripts/benchmarks/*.sh
sudo scripts/setup/01_install_dependencies.sh
```

This script detects the host distro first, refreshes the appropriate package indexes, and installs the required benchmark, Docker, and KVM tooling using the system package manager.

### Step 2 — Set Up Docker Environment

```bash
sudo scripts/setup/02_setup_docker.sh
```

If Docker is not already installed, the script installs it using the distro's package manager and then prepares the benchmark containers, volume, and network.

### Step 3 — Set Up KVM Virtual Machine

```bash
sudo scripts/setup/03_setup_kvm.sh
```
> ⚠️ This step downloads an Ubuntu Server 22.04 cloud image (~600 MB) and creates a VM. It may take 5–10 minutes.

### Step 4 — Run All Benchmarks

```bash
sudo scripts/benchmarks/run_all.sh
```

Results are saved to `results/native/`, `results/docker/`, and `results/kvm/` as plain `.txt` files.

### Step 5 — Generate Charts

```bash
pip install matplotlib pandas numpy
python3 scripts/benchmarks/plot_results.py
```

Charts are saved to the `figures/` directory.

---

## 📊 Key Findings Summary

| Workload           | Docker (vs. Native) | KVM (vs. Native)        |
|--------------------|---------------------|-------------------------|
| CPU (Sysbench)     | ~0% overhead        | ~1–2% overhead          |
| Memory (STREAM)    | ~0% overhead        | ~0–1% overhead          |
| Storage I/O (fio)  | ~2% overhead        | **~40–50% overhead**    |
| Redis Latency      | ~0 µs added         | **~83 µs added/op**     |
| MySQL OLTP         | ~2% overhead        | **>40% overhead**       |

**Conclusion:** Docker containers match native performance in virtually all workloads. KVM imposes near-zero overhead for CPU/memory, but a severe penalty for I/O-intensive workloads — primarily due to virtualized interrupt processing and network emulation overhead.

---

## 📚 References

1. Felter, W. et al. (2015). *An Updated Performance Comparison of Virtual Machines and Linux Containers.* IBM Research / IEEE ISPASS.
2. Morabito, R. et al. (2015). *Hypervisors vs. Lightweight Virtualization: A Performance Comparison.* IEEE IC2E.
3. Agache, A. et al. (2020). *Firecracker: Lightweight Virtualization for Serverless Applications.* USENIX NSDI.
4. Zur, A. et al. (2025). *Nested Virtualization Overhead in Public Cloud Environments.* ACM SIGOPS.

---

## 📝 License

This repository is for academic purposes. Benchmark scripts are released under the MIT License. The seminar report document is © Faisal Javid, Lovely Professional University, 2026.
