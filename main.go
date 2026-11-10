package main

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const version = "0.1.0-dev"
const sshProgram = "/usr/bin/ssh"
const keygenProgram = "/usr/bin/ssh-keygen"

type console struct {
	lines chan string
	ctx   context.Context
}

func newConsole(ctx context.Context) *console {
	c := &console{lines: make(chan string), ctx: ctx}
	go func() {
		defer close(c.lines)
		s := bufio.NewScanner(os.Stdin)
		for s.Scan() {
			select {
			case c.lines <- s.Text():
			case <-ctx.Done():
				return
			}
		}
	}()
	return c
}
func (c *console) ask(prompt string) (string, error) {
	fmt.Print(prompt)
	select {
	case <-c.ctx.Done():
		return "", c.ctx.Err()
	case s, ok := <-c.lines:
		if !ok {
			return "", fmt.Errorf("需要交互式终端输入")
		}
		return strings.TrimSpace(s), nil
	}
}
func (c *console) choose(label string, options []string) (int, error) {
	for i, s := range options {
		fmt.Printf("  %d. %s\n", i+1, s)
	}
	for {
		s, err := c.ask(label + " [1]: ")
		if err != nil {
			return 0, err
		}
		if s == "" {
			return 0, nil
		}
		n, e := strconv.Atoi(s)
		if e == nil && n >= 1 && n <= len(options) {
			return n - 1, nil
		}
		fmt.Println("请输入列表中的编号。")
	}
}
func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "\n"+err.Error())
		os.Exit(1)
	}
}
func run() error {
	bind := flag.String("bind", "", "局域网 IPv4 地址；默认交互选择")
	keyFlag := flag.String("key", "", "已有 SSH 私钥路径，只读取同名 .pub 公钥")
	port := flag.Int("port", 8765, "临时下载服务端口")
	pkgPath := flag.String("package", "", "已下载的固定版本 MSI，仍须通过内置 SHA256 校验")
	showVersion := flag.Bool("version", false, "显示版本")
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return nil
	}
	if runtime.GOOS != "darwin" {
		return fmt.Errorf("首版发起端仅支持 macOS")
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	c := newConsole(ctx)
	ip, network, err := chooseNetwork(c, *bind)
	if err != nil {
		return err
	}
	identity, public, err := chooseKey(c, *keyFlag)
	if err != nil {
		return err
	}
	fmt.Printf("\nOpenSSH %s（官方 Preview），仅供可信局域网使用。\n", packageVersion)
	fmt.Println("已有 SSH 默认复用；这台 Mac 不会发送私钥。安装包会校验固定 SHA256。")
	answer, err := c.ask("准备本次会话？[y/N] ")
	if err != nil {
		return err
	}
	if strings.ToLower(answer) != "y" {
		return nil
	}
	var installer []byte
	if *pkgPath != "" {
		installer, err = os.ReadFile(*pkgPath)
		if err == nil {
			err = checkedPackage(installer, packageSHA256)
		}
	} else {
		cache, e := os.UserCacheDir()
		if e != nil {
			return e
		}
		fmt.Println("准备安装包（优先使用已校验缓存）……")
		installer, err = fetchPackage(ctx, packageURL, packageSHA256, filepath.Join(cache, "lan-ssh-bootstrap", packageVersion, "OpenSSH-Win64.msi"))
	}
	if err != nil {
		return fmt.Errorf("安装包未准备好：%w", err)
	}
	ln, err := net.Listen("tcp4", net.JoinHostPort(ip, strconv.Itoa(*port)))
	if err != nil {
		return err
	}
	base := "http://" + ln.Addr().String()
	s := newSession(base, public, network, installer)
	server := &http.Server{Handler: http.HandlerFunc(s.handler), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 2 * time.Minute, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 8192}
	go func() {
		if e := server.Serve(ln); e != nil && e != http.ErrServerClosed {
			fmt.Fprintln(os.Stderr, e)
			cancel()
		}
	}()
	defer server.Close()
	go func() { <-ctx.Done(); _ = server.Close() }()
	fmt.Printf("\n请让 Windows 操作者在浏览器打开：\n\n  %s\n\n允许网段默认值：%s\n等待安装反馈。Ctrl+C 结束服务。\n", base, network)
	return coordinate(ctx, c, s, identity)
}
func chooseNetwork(c *console, wanted string) (string, string, error) {
	ifaces, err := net.Interfaces()
	if err != nil {
		return "", "", err
	}
	type item struct{ ip, network, label string }
	var items []item
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, _ := iface.Addrs()
		for _, addr := range addrs {
			ip, n, e := net.ParseCIDR(addr.String())
			if e != nil || ip.To4() == nil || !ip.IsPrivate() {
				continue
			}
			n.IP = ip.Mask(n.Mask)
			items = append(items, item{ip.String(), n.String(), iface.Name + "  " + ip.String() + "  " + n.String()})
		}
	}
	sort.Slice(items, func(i, j int) bool { return items[i].label < items[j].label })
	if wanted != "" {
		for _, x := range items {
			if x.ip == wanted {
				return x.ip, x.network, nil
			}
		}
		return "", "", fmt.Errorf("--bind 必须是本机已启用网卡上的私有 IPv4 地址")
	}
	if len(items) == 0 {
		return "", "", fmt.Errorf("没有找到可用的局域网 IPv4 地址")
	}
	opts := make([]string, len(items))
	for i, x := range items {
		opts[i] = x.label
	}
	n, err := c.choose("选择与 Windows 电脑相通的网卡", opts)
	if err != nil {
		return "", "", err
	}
	return items[n].ip, items[n].network, nil
}
func chooseKey(c *console, wanted string) (string, string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", "", err
	}
	if strings.HasPrefix(wanted, "~/") {
		wanted = filepath.Join(home, wanted[2:])
	}
	if wanted == "" {
		pubs, _ := filepath.Glob(filepath.Join(home, ".ssh", "*.pub"))
		var identities, options []string
		for _, pub := range pubs {
			p := strings.TrimSuffix(pub, ".pub")
			if st, e := os.Stat(p); e != nil || !st.Mode().IsRegular() {
				continue
			}
			out, e := exec.Command(keygenProgram, "-lf", pub, "-E", "sha256").Output()
			if e != nil {
				continue
			}
			identities = append(identities, p)
			options = append(options, filepath.Base(p)+"  "+strings.TrimSpace(string(out)))
		}
		if len(identities) == 0 {
			return "", "", fmt.Errorf("没有找到成对的 SSH 密钥。请先运行 ssh-keygen -t ed25519，再重新启动工具；创建时可设置私钥口令")
		}
		i, e := c.choose("选择用于连接的密钥", options)
		if e != nil {
			return "", "", e
		}
		wanted = identities[i]
	}
	wanted, err = filepath.Abs(wanted)
	if err != nil {
		return "", "", err
	}
	if st, e := os.Stat(wanted); e != nil || !st.Mode().IsRegular() {
		return "", "", fmt.Errorf("找不到所选私钥文件")
	}
	data, err := os.ReadFile(wanted + ".pub")
	if err != nil {
		return "", "", err
	}
	p := strings.Fields(string(data))
	if len(p) < 2 || !validHostKey(strings.Join(p[:2], " ")) {
		return "", "", fmt.Errorf("仅支持 Ed25519、RSA 或 NIST P-256 公钥")
	}
	// ssh-keygen validates the public blob; private key bytes are never read here.
	if out, e := exec.Command(keygenProgram, "-lf", wanted+".pub", "-E", "sha256").CombinedOutput(); e != nil {
		return "", "", fmt.Errorf("公钥无效：%s", out)
	}
	return wanted, strings.Join(p[:2], " "), nil
}
func coordinate(ctx context.Context, c *console, s *session, identity string) error {
	var verified target
	var knownHosts string
	for {
		select {
		case <-ctx.Done():
			return nil
		case result := <-s.done:
			if result == "complete" {
				fmt.Printf("\n配置完成。连接命令：\n  ssh -o %s -i %s -p %d -l %s %s\n", shellQuote("UserKnownHostsFile="+sshConfigQuote(knownHosts)), shellQuote(identity), verified.Port, shellQuote(verified.User), verified.IP)
				fmt.Println("首页将再保留 15 秒展示结果，然后关闭服务。")
				select {
				case <-ctx.Done():
				case <-time.After(15 * time.Second):
				}
				return nil
			}
		case t := <-s.ready:
			if t.Stage == "ready" {
				cache, e := os.UserConfigDir()
				if e != nil {
					return e
				}
				dir, e := os.MkdirTemp(filepath.Join(cache), "lan-ssh-bootstrap-")
				if e != nil {
					return e
				}
				knownHosts = filepath.Join(dir, "known_hosts")
				pubPath := filepath.Join(dir, "host.pub")
				if e = os.WriteFile(pubPath, []byte(t.HostKey+"\n"), 0600); e != nil {
					return e
				}
				fp, e := exec.CommandContext(ctx, keygenProgram, "-lf", pubPath, "-E", "sha256").CombinedOutput()
				if e != nil {
					s.setDecision(t.Attempt, "abort")
					fmt.Println("主机公钥无效。")
					continue
				}
				fmt.Printf("\nWindows：%s / %s\n主机指纹：%s", t.IP, t.User, fp)
				a, e := c.ask("请与 Windows PowerShell 上显示的主机指纹核对。相同后输入 yes，其他输入取消：")
				if e != nil {
					return e
				}
				if a != "yes" {
					s.setDecision(t.Attempt, "abort")
					continue
				}
				host := t.IP
				if t.Port != 22 {
					host = "[" + t.IP + "]:" + strconv.Itoa(t.Port)
				}
				if e = os.WriteFile(knownHosts, []byte(host+" "+t.HostKey+"\n"), 0600); e != nil {
					return e
				}
				verified = t
			} else if t.Attempt != verified.Attempt || t.User != verified.User || t.SID != verified.SID || t.HostKey != verified.HostKey || t.IP != verified.IP || t.Port != verified.Port {
				s.setDecision(t.Attempt, "abort")
				fmt.Println("最终验证的设备身份发生变化，已中止。")
				continue
			}
			if err := verifySSH(ctx, t, identity, knownHosts); err != nil {
				fmt.Printf("公钥登录验证失败：%v\n如果私钥有口令，请另开终端执行 ssh-add，再输入 retry。\n", err)
				a, e := c.ask("retry 重试，其他输入取消：")
				if e != nil {
					return e
				}
				if a != "retry" {
					s.setDecision(t.Attempt, "abort")
					continue
				}
				if err = verifySSH(ctx, t, identity, knownHosts); err != nil {
					fmt.Println(err)
					s.setDecision(t.Attempt, "abort")
					continue
				}
			}
			if t.Stage == "ready" {
				s.setDecision(t.Attempt, "verify-pass")
				fmt.Println("公钥登录成功，等待 Windows 完成策略设置……")
			} else {
				s.setDecision(t.Attempt, "finish")
			}
		}
	}
}
func verifySSH(ctx context.Context, t target, identity, knownHosts string) error {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	algorithm := strings.Fields(t.HostKey)[0]
	if algorithm == "ssh-rsa" {
		algorithm = "rsa-sha2-512,rsa-sha2-256"
	}
	args := []string{"-F", "/dev/null", "-o", "BatchMode=yes", "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=8", "-o", "IdentitiesOnly=yes", "-o", "UserKnownHostsFile=" + sshConfigQuote(knownHosts), "-o", "GlobalKnownHostsFile=/dev/null", "-o", "HostKeyAlgorithms=" + algorithm, "-p", strconv.Itoa(t.Port), "-i", identity, "-l", t.User, t.IP, `powershell.exe -NoProfile -NonInteractive -Command "[System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value"`}
	command := exec.CommandContext(ctx, sshProgram, args...)
	var stderr bytes.Buffer
	command.Stderr = &stderr
	out, err := command.Output()
	if err != nil {
		return fmt.Errorf("%w: %s", err, strings.TrimSpace(stderr.String()))
	}
	if strings.TrimSpace(strings.TrimPrefix(string(out), "\ufeff")) != t.SID {
		return errors.New("登录账户 SID 与所选 Windows 账户不符")
	}
	return nil
}
func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'" }

func sshConfigQuote(s string) string {
	return `"` + strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(s) + `"`
}
