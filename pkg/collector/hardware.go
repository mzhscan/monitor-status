package collector

import (
	"fmt"
	"io/ioutil"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type DiskEntry struct {
	Mount   string  `json:"mount"`
	Source  string  `json:"source"`
	UsedGB  float64 `json:"used_gb"`
	TotalGB float64 `json:"total_gb"`
	AvailGB float64 `json:"avail_gb"`
	Percent float64 `json:"percent"`
}

type HardwareData struct {
	CPU     map[string]interface{} `json:"cpu"`
	Memory  map[string]interface{} `json:"memory"`
	GPU     map[string]interface{} `json:"gpu,omitempty"`
	Fan     map[string]interface{} `json:"fan,omitempty"`
	Disks   []DiskEntry           `json:"disks"`
	Disk    map[string]interface{} `json:"disk,omitempty"`
	Load    map[string]interface{} `json:"load"`
	Network map[string]interface{} `json:"network"`
	Uptime  string                 `json:"uptime"`
}

func CollectHardware() map[string]interface{} {
	hw := HardwareData{
		CPU:     readCPU(),
		Memory:  readMemory(),
		Load:    readLoadAvg(),
		Network: readNetwork(),
		Uptime:  readUptime(),
	}

	if gpu := readGPU(); gpu != nil {
		hw.GPU = gpu
	}
	if rpm := readFanRPM(); rpm > 0 {
		hw.Fan = map[string]interface{}{"rpm": rpm}
	}
	disks := readDisks()
	hw.Disks = disks
	// backward-compat: also surface the highest-percent real disk as "disk"
	if len(disks) > 0 {
		worst := disks[0]
		for _, d := range disks[1:] {
			if d.Percent > worst.Percent {
				worst = d
			}
		}
		hw.Disk = map[string]interface{}{
			"percent":  worst.Percent,
			"used_gb":  worst.UsedGB,
			"total_gb": worst.TotalGB,
		}
	}

	return map[string]interface{}{
		"cpu":     hw.CPU,
		"memory":  hw.Memory,
		"gpu":     hw.GPU,
		"fan":     hw.Fan,
		"disks":   hw.Disks,
		"disk":    hw.Disk,
		"load":    hw.Load,
		"network": hw.Network,
		"uptime":  hw.Uptime,
	}
}

// ===== CPU =====
func readCPU() map[string]interface{} {
	// 两次读取 /proc/stat 算差值
	data1 := readProcStat()
	time.Sleep(300 * time.Millisecond)
	data2 := readProcStat()

	total1 := data1["total"]
	total2 := data2["total"]
	idle1 := data1["idle"]
	idle2 := data2["idle"]

	percent := 0.0
	if total2-total1 > 0 {
		percent = float64(total2-total1-(idle2-idle1)) / float64(total2-total1) * 100
	}

	result := map[string]interface{}{
		"percent": round2(percent),
		"temp_c":  round2(readCPUTemp()),
	}
	// 新加：型号 + 核数（用 lscpu，fallback to /proc/cpuinfo）
	if model, cores, ok := readCPUModelAndCores(); ok {
		result["model"] = model
		result["cores"] = cores
	}
	return result
}

func readProcStat() map[string]int64 {
	data := map[string]int64{}
	bytes, _ := ioutil.ReadFile("/proc/stat")
	lines := strings.Split(string(bytes), "\n")
	for _, line := range lines {
		if strings.HasPrefix(line, "cpu ") {
			fields := strings.Fields(line)
			var total, idle int64
			for i, v := range fields[1:] {
				n, _ := strconv.ParseInt(v, 10, 64)
				total += n
				if i == 3 || i == 4 {
					idle += n
				}
			}
			data["total"] = total
			data["idle"] = idle
			return data
		}
	}
	return data
}

// readCPUModelAndCores returns (model, cores). Prefers lscpu output,
// falls back to /proc/cpuinfo + nproc.
func readCPUModelAndCores() (string, int, bool) {
	// Try lscpu first.
	if out, err := runCmd("lscpu"); err == nil {
		model := ""
		cores := 0
		for _, line := range strings.Split(out, "\n") {
			if strings.HasPrefix(line, "Model name:") {
				model = strings.TrimSpace(strings.TrimPrefix(line, "Model name:"))
			} else if strings.HasPrefix(line, "CPU(s):") {
				fields := strings.Fields(line)
				if len(fields) >= 2 {
					if n, err := strconv.Atoi(fields[1]); err == nil {
						cores = n
					}
				}
			} else if strings.HasPrefix(line, "CPU(s) installed:") || strings.HasPrefix(line, "CPU(s) total:") {
				fields := strings.Fields(line)
				if len(fields) >= 2 {
					if n, err := strconv.Atoi(fields[len(fields)-1]); err == nil {
						cores = n
					}
				}
			}
		}
		if model != "" && cores > 0 {
			return model, cores, true
		}
	}
	// Fallback: /proc/cpuinfo
	if data, err := ioutil.ReadFile("/proc/cpuinfo"); err == nil {
		model := ""
		for _, line := range strings.Split(string(data), "\n") {
			if strings.HasPrefix(line, "model name") || strings.HasPrefix(line, "Hardware") {
				parts := strings.SplitN(line, ":", 2)
				if len(parts) == 2 {
					model = strings.TrimSpace(parts[1])
					break
				}
			}
		}
		// Count physical cores via "cpu cores" or fall back to processors
		// listing count.
		cores := 0
		for _, line := range strings.Split(string(data), "\n") {
			if strings.HasPrefix(line, "processor") {
				cores++
			}
		}
		if model != "" && cores > 0 {
			return model, cores, true
		}
	}
	return "", 0, false
}

func readCPUTemp() float64 {
	// 优先 thermal_zone0
	bytes, err := ioutil.ReadFile("/sys/class/thermal/thermal_zone0/temp")
	if err == nil {
		temp, _ := strconv.Atoi(strings.TrimSpace(string(bytes)))
		if temp > 0 {
			return float64(temp) / 1000.0
		}
	}
	// fallback: hwmon cpu 温度
	matches, _ := filepath.Glob("/sys/class/hwmon/hwmon*/name")
	for _, f := range matches {
		name, _ := ioutil.ReadFile(f)
		n := strings.ToLower(strings.TrimSpace(string(name)))
		if strings.Contains(n, "cpu") || strings.Contains(n, "coretemp") || strings.Contains(n, "k10temp") {
			dir := filepath.Dir(f)
			tempBytes, err := ioutil.ReadFile(filepath.Join(dir, "temp1_input"))
			if err == nil {
				temp, _ := strconv.Atoi(strings.TrimSpace(string(tempBytes)))
				if temp > 0 {
					return float64(temp) / 1000.0
				}
			}
		}
	}
	return 0
}

// ===== 内存 =====
func readMemory() map[string]interface{} {
	used, total, percent := readMemInfo()
	return map[string]interface{}{
		"used_mb":  round2(float64(used) / 1024 / 1024),
		"total_mb": round2(float64(total) / 1024 / 1024),
		"percent":  round2(percent),
		"used_gb":  round2(float64(used) / 1024 / 1024 / 1024),
		"total_gb": round2(float64(total) / 1024 / 1024 / 1024),
	}
}

func readMemInfo() (used, total int64, percent float64) {
	bytes, err := ioutil.ReadFile("/proc/meminfo")
	if err != nil {
		return
	}
	memInfo := map[string]int64{}
	for _, line := range strings.Split(string(bytes), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 2 {
			key := strings.TrimSuffix(fields[0], ":")
			val, _ := strconv.ParseInt(fields[1], 10, 64)
			memInfo[key] = val * 1024
		}
	}
	total = memInfo["MemTotal"]
	used = total - memInfo["MemAvailable"]
	if total > 0 {
		percent = float64(used) / float64(total) * 100
	}
	return
}

// ===== 磁盘 =====
func readDisks() []DiskEntry {
	out, err := runCmd("df", "-BG", "--output=source,size,used,avail,pcent,target")
	if err != nil {
		return nil
	}
	lines := strings.Split(out, "\n")
	if len(lines) < 2 {
		return nil
	}

	var entries []DiskEntry
	for _, line := range lines[1:] {
		fields := strings.Fields(line)
		if len(fields) < 6 {
			continue
		}
		source := fields[0]
		sizeStr := strings.TrimSuffix(fields[1], "G")
		usedStr := strings.TrimSuffix(fields[2], "G")
		availStr := strings.TrimSuffix(fields[3], "G")
		pctStr := strings.TrimSuffix(fields[4], "%")
		mount := fields[5]

		if !isRealDisk(mount, source) {
			continue
		}

		total, _ := strconv.ParseFloat(sizeStr, 64)
		used, _ := strconv.ParseFloat(usedStr, 64)
		avail, _ := strconv.ParseFloat(availStr, 64)
		pct, _ := strconv.ParseFloat(pctStr, 64)

		entries = append(entries, DiskEntry{
			Mount:   mount,
			Source:  source,
			UsedGB:  round2(used),
			TotalGB: round2(total),
			AvailGB: round2(avail),
			Percent: round2(pct),
		})
	}
	// sort by percent desc
	for i := 0; i < len(entries); i++ {
		for j := i + 1; j < len(entries); j++ {
			if entries[j].Percent > entries[i].Percent {
				entries[i], entries[j] = entries[j], entries[i]
			}
		}
	}
	return entries
}

func isRealDisk(mount, source string) bool {
	if mount == "/" || mount == "/boot" || mount == "/boot/efi" || mount == "/home" {
		return true
	}
	if strings.HasPrefix(source, "tmpfs") ||
		strings.HasPrefix(source, "devtmpfs") ||
		strings.HasPrefix(source, "udev") ||
		strings.HasPrefix(source, "overlay") ||
		strings.Contains(source, "docker") ||
		strings.HasPrefix(mount, "/dev/shm") ||
		strings.HasPrefix(mount, "/sys") ||
		strings.HasPrefix(mount, "/proc") ||
		strings.HasPrefix(mount, "/run") ||
		strings.Contains(mount, "/docker/overlay") {
		return false
	}
	// Trim NAS / cloud storage virtual mounts — they often surface as
	// huge (1PB+) webdav/cloud volumes that aren't physical disks.
	if strings.HasPrefix(mount, "/vol02/") ||
		strings.Contains(source, ":cloud-storage/") ||
		strings.HasPrefix(source, "1000-1-") ||
		strings.HasPrefix(source, "cloud-") {
		return false
	}
	return true
}

// ===== GPU =====
func readGPU() map[string]interface{} {
	// NVIDIA: 拿 name + util + temp + mem
	if out, err := runCmd("nvidia-smi", "--query-gpu=index,name,utilization.gpu,temperature.gpu,memory.used,memory.total", "--format=csv,noheader,nounits"); err == nil && out != "" {
		fields := strings.Split(strings.TrimSpace(out), ", ")
		if len(fields) >= 6 {
			util, _ := strconv.ParseFloat(strings.TrimSpace(fields[2]), 64)
			temp, _ := strconv.ParseFloat(strings.TrimSpace(fields[3]), 64)
			memUsed, _ := strconv.ParseFloat(strings.TrimSpace(fields[4]), 64)
			memTotal, _ := strconv.ParseFloat(strings.TrimSpace(fields[5]), 64)
			model := strings.TrimSpace(fields[1])
			if model == "" {
				model = "nvidia"
			}
			return map[string]interface{}{
				"vendor":   "nvidia",
				"model":    model,
				"percent":  util,
				"temp_c":   temp,
				"used_mb":  memUsed,
				"total_mb": memTotal,
			}
		}
	}
	// Intel 核显：没有 nvidia-smi，靠 hwmon 温度
	if temp := readIntelGPUTemp(); temp > 0 {
		return map[string]interface{}{
			"vendor": "intel",
			"model":  "intel",
			"temp_c": temp,
		}
	}
	return nil
}

func readIntelGPUTemp() float64 {
	matches, _ := filepath.Glob("/sys/class/hwmon/hwmon*/name")
	for _, f := range matches {
		name, _ := ioutil.ReadFile(f)
		n := strings.ToLower(strings.TrimSpace(string(name)))
		if strings.Contains(n, "i915") || strings.Contains(n, "gpu") || strings.Contains(n, "xe") {
			dir := filepath.Dir(f)
			tempBytes, err := ioutil.ReadFile(filepath.Join(dir, "temp1_input"))
			if err == nil {
				temp, _ := strconv.Atoi(strings.TrimSpace(string(tempBytes)))
				if temp > 0 {
					return float64(temp) / 1000.0
				}
			}
		}
	}
	return 0
}

// ===== 风扇 =====
func readFanRPM() int {
	matches, _ := filepath.Glob("/sys/class/hwmon/hwmon*/fan1_input")
	for _, f := range matches {
		bytes, err := ioutil.ReadFile(f)
		if err == nil {
			rpm, _ := strconv.Atoi(strings.TrimSpace(string(bytes)))
			if rpm > 0 {
				return rpm
			}
		}
	}
	return 0
}

// ===== 负载 =====
func readLoadAvg() map[string]interface{} {
	bytes, err := ioutil.ReadFile("/proc/loadavg")
	if err != nil {
		return nil
	}
	fields := strings.Fields(string(bytes))
	if len(fields) < 3 {
		return nil
	}
	l1, _ := strconv.ParseFloat(fields[0], 64)
	l5, _ := strconv.ParseFloat(fields[1], 64)
	l15, _ := strconv.ParseFloat(fields[2], 64)
	return map[string]interface{}{
		"1min":  round2(l1),
		"5min":  round2(l5),
		"15min": round2(l15),
	}
}

// ===== 网络 =====
// 读 /proc/net/dev，累加物理网卡流量。
// v2.4.19：之前只排除 lo + bond，跑 docker 的机器会把 docker0 / veth* /
// br-* 这些虚拟接口的流量也加进去，数字虚高。改成显式排除所有虚拟接口
// 前缀（docker / veth / br- / virbr / tun / tap），只算物理网卡。
func readNetwork() map[string]interface{} {
	bytes, err := ioutil.ReadFile("/proc/net/dev")
	if err != nil {
		return nil
	}
	var totalRx, totalTx int64
	for _, line := range strings.Split(string(bytes), "\n") {
		// 跳过表头行
		if strings.HasPrefix(line, "Inter") || strings.HasPrefix(line, " face") {
			continue
		}
		// 行首第一个 token 是接口名（带 :），例如 "  eth0:"、"docker0:"。
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		iface := strings.TrimSuffix(fields[0], ":")
		// 排除虚拟接口：lo / bond / docker / veth / br- / virbr / tun / tap
		if isVirtualIface(iface) {
			continue
		}
		if len(fields) >= 9 {
			rx, _ := strconv.ParseInt(fields[1], 10, 64)
			tx, _ := strconv.ParseInt(fields[9], 10, 64)
			totalRx += rx
			totalTx += tx
		}
	}
	return map[string]interface{}{
		"rx_bytes": totalRx,
		"tx_bytes": totalTx,
		"rx_mb":    round2(float64(totalRx) / 1024 / 1024),
		"tx_mb":    round2(float64(totalTx) / 1024 / 1024),
	}
}

// isVirtualIface 列出所有不应该计入"物理网卡流量"的虚拟接口前缀。
// 注意 veth / docker / virbr 等可能是空字符串（如 docker bridge 默认是 docker0，
// 但用户自定义网络可能是 br-xxxxxx），所以用前缀匹配更稳。
func isVirtualIface(name string) bool {
	switch {
	case name == "lo":
		return true
	case strings.HasPrefix(name, "bond"):
		return true
	case strings.HasPrefix(name, "docker"):
		return true
	case strings.HasPrefix(name, "veth"):
		return true
	case strings.HasPrefix(name, "br-"):
		return true
	case strings.HasPrefix(name, "virbr"):
		return true
	case strings.HasPrefix(name, "tun"):
		return true
	case strings.HasPrefix(name, "tap"):
		return true
	}
	return false
}

// ===== 运行时间 =====
func readUptime() string {
	bytes, err := ioutil.ReadFile("/proc/uptime")
	if err != nil {
		return ""
	}
	fields := strings.Fields(string(bytes))
	if len(fields) < 1 {
		return ""
	}
	uptimeSec, _ := strconv.ParseFloat(fields[0], 64)
	days := int(uptimeSec / 86400)
	hours := int((uptimeSec - float64(days*86400)) / 3600)
	mins := int((uptimeSec - float64(days*86400) - float64(hours*3600)) / 60)
	if days > 0 {
		return fmt.Sprintf("%d天%d小时%d分", days, hours, mins)
	}
	if hours > 0 {
		return fmt.Sprintf("%d小时%d分", hours, mins)
	}
	return fmt.Sprintf("%d分", mins)
}

func runCmd(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

func round2(f float64) float64 {
	return float64(int(f*100)) / 100
}

func FileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
