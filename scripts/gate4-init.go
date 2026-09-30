package main
import ("fmt";"os";"os/exec";"syscall";"time")
func main(){
 _=syscall.Mount("devtmpfs","/dev","devtmpfs",0,""); _=syscall.Mount("proc","/proc","proc",0,""); _=syscall.Mount("sysfs","/sys","sysfs",0,""); _=os.MkdirAll("/opt",0755)
 for i:=0;i<40;i++{if st,e:=os.Stat("/dev/sdb");e==nil&&st.Mode()&os.ModeDevice!=0{break};time.Sleep(250*time.Millisecond)}
 st,e:=os.Stat("/dev/sdb");if e!=nil||st.Mode()&os.ModeDevice==0{fmt.Println("GATE4_RESULT=FAIL opt device");syscall.Reboot(syscall.LINUX_REBOOT_CMD_POWER_OFF);return}
 if e:=syscall.Mount("/dev/sdb","/opt","ext4",0,"");e!=nil{fmt.Printf("GATE4_RESULT=FAIL mount=%v\n",e);syscall.Reboot(syscall.LINUX_REBOOT_CMD_POWER_OFF);return}
 c:=exec.Command("/opt/bin/d2kd_parser_test");c.Stdout=os.Stdout;c.Stderr=os.Stderr;e=c.Run();if e!=nil{fmt.Printf("GATE4_RESULT=FAIL parser=%v\n",e)};syscall.Sync();syscall.Reboot(syscall.LINUX_REBOOT_CMD_POWER_OFF)
}