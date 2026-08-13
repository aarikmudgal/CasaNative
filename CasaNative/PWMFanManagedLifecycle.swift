import Foundation

/// Fixed server-side contract for app-managed fan lifecycle operations.
/// Every value interpolated into these scripts originates in validated enums.
enum PWMFanManagedLifecycleScripts {
    static let stateDirectory = "/var/lib/casanative-pwm-fan"
    static let helperPath = "/usr/local/sbin/casanative-pwm-fan"
    static let defaultsPath = "/etc/default/casanative-pwm-fan"
    static let servicePath = "/etc/systemd/system/casanative-pwm-fan.service"

    static let service = """
    [Unit]
    Description=Casa Native managed fan controller
    After=multi-user.target

    [Service]
    Type=oneshot
    ExecStart=/usr/local/sbin/casanative-pwm-fan
    RemainAfterExit=yes

    [Install]
    WantedBy=multi-user.target
    """ + "\n"

    static let legacyHelper = """
    #!/bin/sh
    set -eu

    chip="$(ls -d /sys/class/pwm/pwmchip* 2>/dev/null | head -n1)"
    [ -n "$chip" ] || exit 1

    if [ ! -d "$chip/pwm0" ]; then
      echo 0 > "$chip/export"
    fi

    # 25kHz period = 40000ns
    echo 40000 > "$chip/pwm0/period"
    echo 20000 > "$chip/pwm0/duty_cycle"
    echo 1 > "$chip/pwm0/enable"
    """ + "\n"

    static let legacyService = """
    [Unit]
    Description=Set GPIO18 fan to 50% PWM
    After=multi-user.target

    [Service]
    Type=oneshot
    ExecStart=/usr/local/bin/fan50.sh
    RemainAfterExit=yes

    [Install]
    WantedBy=multi-user.target
    """ + "\n"

    /// Boot-time helper. It never edits configuration or lifecycle state.
    /// It selects a manual source/target only when the exact boot block,
    /// journal, boot generation, and state assets agree.
    static let helper = #"""
#!/bin/sh
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
STATE=/var/lib/casanative-pwm-fan
STATE_STAGE=/var/lib/.casanative-pwm-fan.new
STATE_REMOVAL=/var/lib/.casanative-pwm-fan.removing
LOCK="$STATE/lock"
DEFAULT=/etc/default/casanative-pwm-fan

regular_root_file() {
  [ -f "$1" ] && [ ! -L "$1" ] &&
    [ "$(stat -c %g "$1" 2>/dev/null || :)" = 0 ] &&
    [ "$(stat -c '%u:%a:%h' "$1" 2>/dev/null || :)" = "$2" ]
}
trusted_parent() {
  path="$1"
  [ -d "$path" ] && [ ! -L "$path" ] && [ "$(stat -c '%u:%g' "$path" 2>/dev/null || :)" = 0:0 ] || return 1
  mode="$(stat -c %a "$path" 2>/dev/null || :)"; case "$mode" in ???|????) :;; *) return 1;; esac
  group="$(printf '%s' "$mode" | cut -c$((${#mode}-1)))"; other="$(printf '%s' "$mode" | cut -c${#mode})"; case "$group$other" in *[2367]*) return 1;; esac
}
validate_fixed_parents() {
  for parent in /usr /usr/local /usr/local/bin /usr/local/sbin /etc /etc/default /etc/systemd /etc/systemd/system /var /var/lib; do trusted_parent "$parent" || exit 75; done
}
canonical_journal_shape() {
  regular_root_file "$1" '0:600:1' || return 1
  awk -F= '
    BEGIN{key[1]="VERSION";key[2]="PHASE";key[3]="KIND";key[4]="REQUIREMENT";key[5]="PREPARED_BOOT_ID";key[6]="SOURCE_MODE";key[7]="SOURCE_PIN";key[8]="SOURCE_DUTY";key[9]="SOURCE_TEMP";key[10]="SOURCE_HYST";key[11]="TARGET_MODE";key[12]="TARGET_PIN";key[13]="TARGET_DUTY";key[14]="TARGET_TEMP";key[15]="TARGET_HYST";key[16]="SOURCE_SERVICE_ENABLED";key[17]="TARGET_SERVICE_ENABLED";ok=1}
    {if(NR>17 || $1!=key[NR] || index(substr($0,length($1)+2),"=") || $0 ~ /[[:cntrl:]]/)ok=0}
    END{exit !(ok && NR==17)}
  ' "$1" || return 1
  [ "$(sed -n '1p' "$1")" = VERSION=2 ] || return 1
  phase="$(sed -n '2s/^PHASE=//p' "$1")"; case "$phase" in prepared|cancelling|finalizing|legacyConverting|legacyRestoring|legacyDiscarding|applying) :;; *) return 1;; esac
  kind="$(sed -n '3s/^KIND=//p' "$1")"; case "$kind" in change|rollback|uninstall) :;; *) return 1;; esac
  requirement="$(sed -n '4s/^REQUIREMENT=//p' "$1")"; case "$requirement" in reboot|shutdown) :;; *) return 1;; esac
  prepared="$(sed -n '5s/^PREPARED_BOOT_ID=//p' "$1")"; printf '%s\n' "$prepared" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || return 1
  source_mode="$(sed -n '6s/^SOURCE_MODE=//p' "$1")"; source_pin="$(sed -n '7s/^SOURCE_PIN=//p' "$1")"; source_duty="$(sed -n '8s/^SOURCE_DUTY=//p' "$1")"; source_temp="$(sed -n '9s/^SOURCE_TEMP=//p' "$1")"; source_hyst="$(sed -n '10s/^SOURCE_HYST=//p' "$1")"
  target_mode="$(sed -n '11s/^TARGET_MODE=//p' "$1")"; target_pin="$(sed -n '12s/^TARGET_PIN=//p' "$1")"; target_duty="$(sed -n '13s/^TARGET_DUTY=//p' "$1")"; target_temp="$(sed -n '14s/^TARGET_TEMP=//p' "$1")"; target_hyst="$(sed -n '15s/^TARGET_HYST=//p' "$1")"
  case "$phase" in
    legacyConverting) [ "$kind:$requirement:$source_mode:$target_mode:$target_pin:$target_duty" = change:reboot:none:manual:18:50 ] || return 1;;
    legacyRestoring|legacyDiscarding) [ "$kind:$requirement:$source_mode:$source_pin:$source_duty:$target_mode:$target_pin:$target_duty" = change:reboot:manual:18:50:manual:18:50 ] || return 1;;
    applying) [ "$kind:$requirement:$source_mode:$target_mode:$source_pin" = "change:reboot:manual:manual:$target_pin" ] || return 1;;
    *)
      if [ "$source_mode" != none ] && [ "$target_mode" != uninstalled ]; then
        if [ "$source_mode" != "$target_mode" ]; then [ "$source_pin" = "$target_pin" ] || return 1
        elif [ "$source_mode" = manual ]; then [ "$source_pin" != "$target_pin" ] && [ "$source_duty" = "$target_duty" ] || return 1
        elif [ "$source_pin" = "$target_pin" ]; then { [ "$source_temp" != "$target_temp" ] || [ "$source_hyst" != "$target_hyst" ]; } || return 1
        else [ "$source_temp" = "$target_temp" ] && [ "$source_hyst" = "$target_hyst" ] || return 1; fi
      fi;;
  esac
  return 0
}

validate_fixed_parents
[ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 75
[ "$(stat -c '%u:%g:%a' "$STATE" 2>/dev/null || :)" = '0:0:700' ] || exit 75
regular_root_file "$LOCK" '0:600:1' || exit 75
exec 9<"$LOCK"
flock -x -w 3 9 || exit 75

CFG=''
if [ -e /boot/firmware/config.txt ] || [ -L /boot/firmware/config.txt ]; then
  [ -f /boot/firmware/config.txt ] && [ ! -L /boot/firmware/config.txt ] || exit 75
  CFG=/boot/firmware/config.txt
elif [ -e /boot/config.txt ] || [ -L /boot/config.txt ]; then
  [ -f /boot/config.txt ] && [ ! -L /boot/config.txt ] || exit 75
  CFG=/boot/config.txt
else
  exit 75
fi
[ "$(stat -c '%u:%g:%h:%F' "$CFG" 2>/dev/null || :)" = '0:0:1:regular file' ] || exit 75
cfg_mode="$(stat -c %a "$CFG" 2>/dev/null || :)"; case "$cfg_mode" in ???|????) :;; *) exit 75;; esac
cfg_group="$(printf '%s' "$cfg_mode" | cut -c$((${#cfg_mode}-1)))"; cfg_other="$(printf '%s' "$cfg_mode" | cut -c${#cfg_mode})"; case "$cfg_group$cfg_other" in *[2367]*) exit 75;; esac
cfg_parent="${CFG%/*}"; [ -d "$cfg_parent" ] && [ ! -L "$cfg_parent" ] && [ "$(stat -c '%u:%g' "$cfg_parent" 2>/dev/null || :)" = 0:0 ] || exit 75
grep -Eiq '^[[:space:]]*include[[:space:]]+' "$CFG" && exit 75

config_record="$(awk '
  function clean(v){sub(/\r$/, "", v); return v}
  BEGIN{scope="all"; found=0; state="invalid"; pin=""}
  {
    line=clean($0)
    if(line ~ /^[[:space:]]*\[[^]]+\][[:space:]]*$/){
      section=line; gsub(/[[:space:]\[\]]/, "", section); scope=section; next
    }
    if(line=="# BEGIN CasaNative PWM Fan"){
      a=""; b=""; if((getline a)<=0 || (getline b)<=0){bad=1; next}
      a=clean(a); b=clean(b)
      if(scope!="all" || b!="# END CasaNative PWM Fan" || a !~ /^dtoverlay=pwm,pin=(12|13|18|19),func=(2|4)$/){bad=1; next}
      n=split(a,p,","); split(p[2],x,"="); split(p[3],y,"=")
      if((x[2]==12 || x[2]==13) && y[2]!=4) bad=1
      else if((x[2]==18 || x[2]==19) && y[2]!=2) bad=1
      else {found++; state="manual"; pin=x[2]}
      next
    }
    if(line=="# BEGIN CasaNative GPIO Fan"){
      a=""; b=""; if((getline a)<=0 || (getline b)<=0){bad=1; next}
      a=clean(a); b=clean(b)
      if(scope!="all" || b!="# END CasaNative GPIO Fan" || a !~ /^dtoverlay=gpio-fan,gpiopin=(12|13|18|19),temp=([4-7][0-9]000),hyst=([5-9]000|1[0-5]000)$/) bad=1
      else {split(a,p,","); split(p[2],x,"="); found++; state="automatic"; pin=x[2]}
      next
    }
  }
  END{if(bad || found!=1) print "invalid|"; else print state "|" pin}
' "$CFG")"

read_default() {
  regular_root_file "$DEFAULT" '0:644:1' || return 1
  [ "$(wc -l < "$DEFAULT" | tr -d ' ')" = 3 ] || return 1
  mode="$(sed -n '1s/^MODE=//p' "$DEFAULT")"
  pin="$(sed -n '2s/^PIN=//p' "$DEFAULT")"
  duty="$(sed -n '3s/^DUTY_PERCENT=//p' "$DEFAULT")"
  case "$mode:$pin:$duty" in
    manual:12:*|manual:13:*|manual:18:*|manual:19:*) :;;
    automatic:12:0|automatic:13:0|automatic:18:0|automatic:19:0) :;;
    *) return 1;;
  esac
  case "$duty" in ''|*[!0-9]*) return 1;; esac
  [ "$duty" -le 100 ] || return 1
  printf '%s|%s|%s\n' "$mode" "$pin" "$duty"
}

stable="$(read_default 2>/dev/null || :)"
selected=''
JOURNAL="$STATE/journal"
if [ -e "$JOURNAL" ] || [ -L "$JOURNAL" ]; then
  regular_root_file "$JOURNAL" '0:600:1' || exit 75
  [ "$(wc -l < "$JOURNAL" | tr -d ' ')" = 17 ] || exit 75
  version="$(sed -n '1s/^VERSION=//p' "$JOURNAL")"
  phase="$(sed -n '2s/^PHASE=//p' "$JOURNAL")"
  kind="$(sed -n '3s/^KIND=//p' "$JOURNAL")"
  requirement="$(sed -n '4s/^REQUIREMENT=//p' "$JOURNAL")"
  prepared="$(sed -n '5s/^PREPARED_BOOT_ID=//p' "$JOURNAL")"
  source_mode="$(sed -n '6s/^SOURCE_MODE=//p' "$JOURNAL")"
  source_pin="$(sed -n '7s/^SOURCE_PIN=//p' "$JOURNAL")"
  source_duty="$(sed -n '8s/^SOURCE_DUTY=//p' "$JOURNAL")"
  source_temp="$(sed -n '9s/^SOURCE_TEMP=//p' "$JOURNAL")"
  source_hyst="$(sed -n '10s/^SOURCE_HYST=//p' "$JOURNAL")"
  target_mode="$(sed -n '11s/^TARGET_MODE=//p' "$JOURNAL")"
  target_pin="$(sed -n '12s/^TARGET_PIN=//p' "$JOURNAL")"
  target_duty="$(sed -n '13s/^TARGET_DUTY=//p' "$JOURNAL")"
  target_temp="$(sed -n '14s/^TARGET_TEMP=//p' "$JOURNAL")"
  target_hyst="$(sed -n '15s/^TARGET_HYST=//p' "$JOURNAL")"
  source_service="$(sed -n '16s/^SOURCE_SERVICE_ENABLED=//p' "$JOURNAL")"
  target_service="$(sed -n '17s/^TARGET_SERVICE_ENABLED=//p' "$JOURNAL")"
  journal_valid=1
  [ "$version" = 2 ] || journal_valid=0
  case "$kind:$requirement" in change:reboot|change:shutdown|rollback:reboot|rollback:shutdown|uninstall:shutdown) :;; *) journal_valid=0;; esac
  case "$phase" in prepared|cancelling|finalizing|legacyConverting|legacyRestoring|legacyDiscarding|applying) :;; *) journal_valid=0;; esac
  printf '%s\n' "$prepared" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || journal_valid=0
  case "$source_mode:$source_pin:$source_duty:$source_temp:$source_hyst" in none::::|manual:12:*::|manual:13:*::|manual:18:*::|manual:19:*::|automatic:12::[4-7][0-9]:[5-9]|automatic:12::[4-7][0-9]:1[0-5]|automatic:13::[4-7][0-9]:[5-9]|automatic:13::[4-7][0-9]:1[0-5]|automatic:18::[4-7][0-9]:[5-9]|automatic:18::[4-7][0-9]:1[0-5]|automatic:19::[4-7][0-9]:[5-9]|automatic:19::[4-7][0-9]:1[0-5]) :;; *) journal_valid=0;; esac
  case "$target_mode:$target_pin:$target_duty:$target_temp:$target_hyst" in manual:12:*::|manual:13:*::|manual:18:*::|manual:19:*::|automatic:12::[4-7][0-9]:[5-9]|automatic:12::[4-7][0-9]:1[0-5]|automatic:13::[4-7][0-9]:[5-9]|automatic:13::[4-7][0-9]:1[0-5]|automatic:18::[4-7][0-9]:[5-9]|automatic:18::[4-7][0-9]:1[0-5]|automatic:19::[4-7][0-9]:[5-9]|automatic:19::[4-7][0-9]:1[0-5]|uninstalled::::) :;; *) journal_valid=0;; esac
  case "$source_duty:$target_duty:$source_temp:$source_hyst:$target_temp:$target_hyst" in *[!0-9:]* ) journal_valid=0;; esac
  [ -z "$source_duty" ] || [ "$source_duty" -le 100 ] || journal_valid=0
  [ -z "$target_duty" ] || [ "$target_duty" -le 100 ] || journal_valid=0
  if [ "$source_mode" = automatic ]; then [ "$source_temp" -ge 40 ] && [ "$source_temp" -le 75 ] && [ "$source_hyst" -ge 5 ] && [ "$source_hyst" -le 15 ] && [ $((source_temp-source_hyst)) -ge 30 ] || journal_valid=0; fi
  if [ "$target_mode" = automatic ]; then [ "$target_temp" -ge 40 ] && [ "$target_temp" -le 75 ] && [ "$target_hyst" -ge 5 ] && [ "$target_hyst" -le 15 ] && [ $((target_temp-target_hyst)) -ge 30 ] || journal_valid=0; fi
  case "$kind:$target_mode:$source_mode" in uninstall:uninstalled:manual|uninstall:uninstalled:automatic|change:manual:none|change:automatic:none|change:manual:manual|change:manual:automatic|change:automatic:manual|change:automatic:automatic|rollback:manual:none|rollback:automatic:none|rollback:uninstalled:manual|rollback:uninstalled:automatic|rollback:manual:manual|rollback:manual:automatic|rollback:automatic:manual|rollback:automatic:automatic) :;; *) journal_valid=0;; esac
  expected_source_service=0; [ "$source_mode" = manual ] && expected_source_service=1
  expected_target_service=0; { [ "$source_mode" = manual ] || [ "$target_mode" = manual ]; } && expected_target_service=1
  [ "$source_service" = "$expected_source_service" ] && [ "$target_service" = "$expected_target_service" ] || journal_valid=0
  if [ "$target_mode" = uninstalled ] || { [ "$kind" = rollback ] && [ "$source_mode" = none ]; } || { [ "$source_mode" != none ] && [ "$source_pin" != "$target_pin" ]; }; then [ "$requirement" = shutdown ] || journal_valid=0; else [ "$requirement" = reboot ] || journal_valid=0; fi
  case "$phase" in
    legacyConverting) [ "$kind:$requirement:$source_mode:$target_mode:$target_pin:$target_duty" = change:reboot:none:manual:18:50 ] || journal_valid=0;;
    legacyRestoring|legacyDiscarding) [ "$kind:$requirement:$source_mode:$source_pin:$source_duty:$target_mode:$target_pin:$target_duty" = change:reboot:manual:18:50:manual:18:50 ] || journal_valid=0;;
    applying) [ "$kind:$requirement:$source_mode:$target_mode" = change:reboot:manual:manual ] && [ "$source_pin" = "$target_pin" ] || journal_valid=0;;
    *)
      if [ "$source_mode" != none ] && [ "$target_mode" != uninstalled ]; then
        if [ "$source_mode" != "$target_mode" ]; then
          [ "$source_pin" = "$target_pin" ] || journal_valid=0
        elif [ "$source_mode" = manual ]; then
          [ "$source_pin" != "$target_pin" ] && [ "$source_duty" = "$target_duty" ] || journal_valid=0
        elif [ "$source_pin" = "$target_pin" ]; then
          { [ "$source_temp" != "$target_temp" ] || [ "$source_hyst" != "$target_hyst" ]; } || journal_valid=0
        else
          [ "$source_temp" = "$target_temp" ] && [ "$source_hyst" = "$target_hyst" ] || journal_valid=0
        fi
      fi
      ;;
  esac
  current="$(cat /proc/sys/kernel/random/boot_id)"
  source="$source_mode|$source_pin|$source_duty"
  target="$target_mode|$target_pin|$target_duty"
  if [ "$journal_valid" != 1 ]; then
    case "$config_record" in manual\|12|manual\|13|manual\|18|manual\|19) selected="${config_record}|100";; *) exit 0;; esac
  elif [ "$phase" = finalizing ] || [ "$phase" = legacyConverting ] || [ "$phase" = applying ]; then
    if [ "$config_record" = "$target_mode|$target_pin" ]; then selected="$target"
    elif [ "$config_record" = "$source_mode|$source_pin" ]; then selected="$source"
    else exit 0; fi
  elif [ "$phase" = cancelling ] || [ "$phase" = legacyRestoring ]; then
    if [ "$config_record" = "$source_mode|$source_pin" ]; then selected="$source"
    elif [ "$config_record" = "$target_mode|$target_pin" ] && [ "$target_mode" = manual ]; then selected="$target"
    else exit 0; fi
  elif [ "$phase" = legacyDiscarding ]; then
    if [ "$config_record" = "$source_mode|$source_pin" ]; then selected="$source"
    elif [ "$config_record" = "$target_mode|$target_pin" ]; then selected="$target"
    else exit 0; fi
  elif [ "$config_record" = "$source_mode|$source_pin" ]; then selected="$source"
  elif [ "$config_record" = "$target_mode|$target_pin" ] && [ "$current" != "$prepared" ]; then selected="$target"
  else
    exit 0
  fi
else
  selected="$stable"
  mode="${stable%%|*}"
  rest="${stable#*|}"
  pin="${rest%%|*}"
  [ "$config_record" = "$mode|$pin" ] || exit 0
fi

mode="${selected%%|*}"
rest="${selected#*|}"
pin="${rest%%|*}"
duty="${rest#*|}"
[ "$mode" = manual ] || exit 0
case "$pin" in 12|13|18|19) :;; *) exit 75;; esac
case "$duty" in ''|*[!0-9]*) duty=100;; esac
[ "$duty" -le 100 ] || duty=100
case "$pin" in 12|18) channel=0;; 13|19) channel=1;; esac

chip=''; matches=0
for candidate in /sys/class/pwm/pwmchip*; do
  [ -d "$candidate" ] || continue
  [ -r "$candidate/npwm" ] || continue
  [ -r "$candidate/device/of_node/compatible" ] || continue
  compatible="$(tr '\000' '\n' < "$candidate/device/of_node/compatible" 2>/dev/null || :)"
  printf '%s\n' "$compatible" | grep -Eq '^(brcm,bcm2835-pwm|brcm,bcm2711-pwm|brcm,bcm2712-pwm|raspberrypi,rp1-pwm)$' || continue
  npwm="$(cat "$candidate/npwm")"
  case "$npwm" in ''|*[!0-9]*) continue;; esac
  [ "$npwm" -gt "$channel" ] || continue
  chip="$candidate"; matches=$((matches + 1))
done
[ "$matches" = 1 ] || exit 75
created=0
if [ ! -d "$chip/pwm$channel" ]; then
  printf '%s\n' "$channel" > "$chip/export"
  created=1; tries=0
  while [ ! -d "$chip/pwm$channel" ] && [ "$tries" -lt 20 ]; do
    sleep 0.05; tries=$((tries + 1))
  done
fi
pwm="$chip/pwm$channel"
[ -d "$pwm" ] || exit 75
old_period="$(cat "$pwm/period" 2>/dev/null || :)"
old_duty="$(cat "$pwm/duty_cycle" 2>/dev/null || :)"
old_enabled="$(cat "$pwm/enable" 2>/dev/null || :)"
case "$old_period:$old_duty:$old_enabled" in *[!0-9:]*|*::* ) exit 75;; esac
modified=0
fail_safe() {
  printf '%s\n' 0 > "$pwm/enable" 2>/dev/null || :
  printf '%s\n' 0 > "$pwm/duty_cycle" 2>/dev/null || :
  printf '%s\n' 40000 > "$pwm/period" 2>/dev/null || :
  printf '%s\n' 40000 > "$pwm/duty_cycle" 2>/dev/null || :
  printf '%s\n' 1 > "$pwm/enable" 2>/dev/null || :
}
rollback() {
  result="$?"
  if [ "$result" -ne 0 ] && [ "$modified" = 1 ]; then
    if [ "$created" = 0 ] && [ "$old_period" -gt 0 ]; then
      printf '%s\n' 0 > "$pwm/enable" 2>/dev/null || :
      printf '%s\n' 0 > "$pwm/duty_cycle" 2>/dev/null || :
      printf '%s\n' "$old_period" > "$pwm/period" 2>/dev/null || { fail_safe; exit "$result"; }
      printf '%s\n' "$old_duty" > "$pwm/duty_cycle" 2>/dev/null || { fail_safe; exit "$result"; }
      printf '%s\n' "$old_enabled" > "$pwm/enable" 2>/dev/null || fail_safe
    else
      fail_safe
    fi
  fi
  exit "$result"
}
trap rollback EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
modified=1
[ "$old_enabled" = 0 ] || printf '%s\n' 0 > "$pwm/enable"
printf '%s\n' 0 > "$pwm/duty_cycle"
printf '%s\n' 40000 > "$pwm/period"
new_duty=$((40000 * duty / 100))
printf '%s\n' "$new_duty" > "$pwm/duty_cycle"
printf '%s\n' 1 > "$pwm/enable"
modified=0
trap - EXIT HUP INT TERM
"""# + "\n"

    static let detectionShell: String = {
        let expectedHelper = base64(helper)
        let expectedService = base64(service)
        let expectedLegacyHelper = base64(legacyHelper)
        let expectedLegacyService = base64(legacyService)
        return #"""
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
STATE=/var/lib/casanative-pwm-fan
STATE_STAGE=/var/lib/.casanative-pwm-fan.new
STATE_REMOVAL=/var/lib/.casanative-pwm-fan.removing
LOCK="$STATE/lock"
emit() { printf '%s\t%s\n' "$1" "$2"; }
regular_root_file() {
  [ -f "$1" ] && [ ! -L "$1" ] &&
    [ "$(stat -c %g "$1" 2>/dev/null || :)" = 0 ] &&
    [ "$(stat -c '%u:%a:%h' "$1" 2>/dev/null || :)" = "$2" ]
}
trusted_parent() {
  path="$1"
  [ -d "$path" ] && [ ! -L "$path" ] && [ "$(stat -c '%u:%g' "$path" 2>/dev/null || :)" = 0:0 ] || return 1
  mode="$(stat -c %a "$path" 2>/dev/null || :)"; case "$mode" in ???|????) :;; *) return 1;; esac
  group="$(printf '%s' "$mode" | cut -c$((${#mode}-1)))"; other="$(printf '%s' "$mode" | cut -c${#mode})"; case "$group$other" in *[2367]*) return 1;; esac
}
fixed_parents_valid=1
for parent in /usr /usr/local /usr/local/bin /usr/local/sbin /etc /etc/default /etc/systemd /etc/systemd/system /var /var/lib; do trusted_parent "$parent" || fixed_parents_valid=0; done
if [ "$fixed_parents_valid" != 1 ]; then
  printf '%s\n' CASANATIVE_PWM_FAN_V3
  emit config 0; emit resource_conflict 1; emit unsupported_pwm_gpio 0; emit manual_capable 0; emit automatic_capable 0; emit managed_files none
  for key in disk_state disk_pin disk_duty disk_temp disk_hyst live_state live_pin live_duty live_temp live_hyst live_period live_enabled automatic_demand transition journal_phase recovery_action transition_kind transition_requirement source_state source_pin source_duty source_temp source_hyst target_state target_pin target_duty target_temp target_hyst legacy pigs pigs_path pigpio_version pigpio_pin pigpio_duty pigpio_frequency pigpio_mode; do case "$key" in disk_state|live_state|transition|legacy|pigs) emit "$key" none;; *) emit "$key" '';; esac; done
  emit recovery 1
  exit 0
fi
canonical_journal_shape() {
  regular_root_file "$1" '0:600:1' || return 1
  awk -F= '
    BEGIN{key[1]="VERSION";key[2]="PHASE";key[3]="KIND";key[4]="REQUIREMENT";key[5]="PREPARED_BOOT_ID";key[6]="SOURCE_MODE";key[7]="SOURCE_PIN";key[8]="SOURCE_DUTY";key[9]="SOURCE_TEMP";key[10]="SOURCE_HYST";key[11]="TARGET_MODE";key[12]="TARGET_PIN";key[13]="TARGET_DUTY";key[14]="TARGET_TEMP";key[15]="TARGET_HYST";key[16]="SOURCE_SERVICE_ENABLED";key[17]="TARGET_SERVICE_ENABLED";ok=1}
    {if(NR>17 || $1!=key[NR] || index(substr($0,length($1)+2),"=") || $0 ~ /[[:cntrl:]]/)ok=0}
    END{exit !(ok && NR==17)}
  ' "$1" || return 1
  [ "$(sed -n '1p' "$1")" = VERSION=2 ] || return 1
  phase="$(sed -n '2s/^PHASE=//p' "$1")"; case "$phase" in prepared|cancelling|finalizing|legacyConverting|legacyRestoring|legacyDiscarding|applying) :;; *) return 1;; esac
  kind="$(sed -n '3s/^KIND=//p' "$1")"; case "$kind" in change|rollback|uninstall) :;; *) return 1;; esac
  requirement="$(sed -n '4s/^REQUIREMENT=//p' "$1")"; case "$requirement" in reboot|shutdown) :;; *) return 1;; esac
  prepared="$(sed -n '5s/^PREPARED_BOOT_ID=//p' "$1")"; printf '%s\n' "$prepared" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || return 1
  return 0
}

# Managed snapshots are serialized before boot-config, asset, or live reads.
early_state_present=0
if [ -e "$STATE_STAGE" ] || [ -L "$STATE_STAGE" ]; then
  # A freshly staged root-owned journal is recoverable by the explicit setup
  # or conversion retry, but it is never interpreted as an absent system.
  [ -d "$STATE_STAGE" ] && [ ! -L "$STATE_STAGE" ] && [ "$(stat -c '%u:%g:%a' "$STATE_STAGE" 2>/dev/null || :)" = '0:0:700' ] || exit 75
  stage_complete=1
  for item in "$STATE_STAGE"/*; do
    [ -e "$item" ] || [ -L "$item" ] || continue
    case "${item##*/}" in lock|journal) regular_root_file "$item" '0:600:1' || exit 75;; *) exit 75;; esac
  done
  regular_root_file "$STATE_STAGE/lock" '0:600:1' || stage_complete=0
  canonical_journal_shape "$STATE_STAGE/journal" || stage_complete=0
  if [ "$stage_complete" = 1 ]; then exec 9<"$STATE_STAGE/lock"; flock -s -w 3 9 || exit 75; fi
  stage_recovery=1
else
  stage_recovery=0
fi
if [ -e "$STATE_REMOVAL" ] || [ -L "$STATE_REMOVAL" ]; then
  [ -d "$STATE_REMOVAL" ] && [ ! -L "$STATE_REMOVAL" ] && [ "$(stat -c '%u:%g:%a' "$STATE_REMOVAL" 2>/dev/null || :)" = '0:0:700' ] || exit 75
  for item in "$STATE_REMOVAL"/*; do [ -e "$item" ] || [ -L "$item" ] || continue; case "${item##*/}" in lock|journal) :;; *) exit 75;; esac; done
  if [ -e "$STATE_REMOVAL/lock" ] || [ -L "$STATE_REMOVAL/lock" ]; then regular_root_file "$STATE_REMOVAL/lock" '0:600:1' || exit 75; exec 8<"$STATE_REMOVAL/lock"; flock -s -w 3 8 || exit 75; fi
  if [ -e "$STATE_REMOVAL/journal" ] || [ -L "$STATE_REMOVAL/journal" ]; then canonical_journal_shape "$STATE_REMOVAL/journal" || exit 75; fi
  removal_recovery=1
else
  removal_recovery=0
fi
[ "$removal_recovery" = 0 ] || { [ "$stage_recovery" = 0 ] && [ ! -e "$STATE" ] && [ ! -L "$STATE" ]; }
[ "$stage_recovery" = 0 ] || { [ ! -e "$STATE" ] && [ ! -L "$STATE" ]; }
if [ "$stage_recovery" = 1 ] && [ "${stage_complete:-0}" = 0 ] && regular_root_file "$STATE_STAGE/lock" '0:600:1'; then
  exec 9<"$STATE_STAGE/lock"; flock -s -w 3 9 || exit 75
fi
if [ -e "$STATE" ] || [ -L "$STATE" ]; then
  early_state_present=1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] && [ "$(stat -c '%u:%g:%a' "$STATE" 2>/dev/null || :)" = '0:0:700' ] || exit 75
  regular_root_file "$LOCK" '0:600:1' || exit 75
  exec 9<"$LOCK"
  flock -s -w 3 9 || exit 75
fi

config=1; recovery=0; partial_temp_recovery=0; CFG=''
if [ -e /boot/firmware/config.txt ] || [ -L /boot/firmware/config.txt ]; then
  if [ -f /boot/firmware/config.txt ] && [ ! -L /boot/firmware/config.txt ]; then CFG=/boot/firmware/config.txt; else config=0; recovery=1; fi
elif [ -e /boot/config.txt ] || [ -L /boot/config.txt ]; then
  if [ -f /boot/config.txt ] && [ ! -L /boot/config.txt ]; then CFG=/boot/config.txt; else config=0; recovery=1; fi
else
  config=0; recovery=1
fi
if [ "$config" = 1 ]; then
  [ "$(stat -c '%u:%g:%h:%F' "$CFG" 2>/dev/null || :)" = '0:0:1:regular file' ] || recovery=1
  cfg_mode="$(stat -c %a "$CFG" 2>/dev/null || :)"; case "$cfg_mode" in ???|????) :;; *) recovery=1;; esac
  cfg_group="$(printf '%s' "$cfg_mode" | cut -c$((${#cfg_mode}-1)))"; cfg_other="$(printf '%s' "$cfg_mode" | cut -c${#cfg_mode})"; case "$cfg_group$cfg_other" in *[2367]*) recovery=1;; esac
  cfg_parent="${CFG%/*}"; [ -d "$cfg_parent" ] && [ ! -L "$cfg_parent" ] && [ "$(stat -c '%u:%g' "$cfg_parent" 2>/dev/null || :)" = 0:0 ] || recovery=1
fi
if [ "$config" = 1 ] && grep -Eiq '^[[:space:]]*include[[:space:]]+' "$CFG"; then recovery=1; fi
if [ "$config" = 1 ]; then
  cfg_dir="${CFG%/*}"
  cfg_temp="$cfg_dir/.casanative-pwm-fan.tmp"
  if [ -e "$cfg_temp" ] || [ -L "$cfg_temp" ]; then
    [ -f "$cfg_temp" ] && [ ! -L "$cfg_temp" ] && [ "$(stat -c '%u:%g:%h' "$cfg_temp" 2>/dev/null || :)" = '0:0:1' ] || exit 75
    case "$(stat -c %a "$cfg_temp" 2>/dev/null || :)" in 600|"$cfg_mode") :;; *) exit 75;; esac
    partial_temp_recovery=1; recovery=1
  fi
fi

disk_state=none; disk_pin=''; disk_duty=''; disk_temp=''; disk_hyst=''
resource_conflict=0; unsupported_pwm_gpio=0; config_invalid=0
legacy_block=0
if [ "$config" = 1 ]; then
  inspected="$(awk '
    function clean(v){sub(/\r$/, "", v); return v}
    function add(stateValue,pinValue,dutyValue,tempValue,hystValue){count++; state=stateValue; pin=pinValue; duty=dutyValue; temp=tempValue; hyst=hystValue}
    BEGIN{scope="all"; state="none"; pin=""; duty=""; temp=""; hyst=""; count=0; resource=0; unsupported=0; invalid=0; legacy=0}
    {
      line=clean($0)
      if(line ~ /^[[:space:]]*\[[^]]+\][[:space:]]*$/){section=line; gsub(/[[:space:]\[\]]/, "", section); scope=section; next}
      if(line=="# BEGIN CasaNative PWM Fan"){
        firstLine=""; endLine=""; if((getline firstLine)<=0 || (getline endLine)<=0){invalid=1; next}; firstLine=clean(firstLine); endLine=clean(endLine)
        if(scope!="all" || endLine!="# END CasaNative PWM Fan" || firstLine !~ /^dtoverlay=pwm,pin=(12|13|18|19),func=(2|4)$/){invalid=1; next}
        split(firstLine,manualParts,","); split(manualParts[2],manualPinPair,"="); split(manualParts[3],manualFuncPair,"=")
        if(((manualPinPair[2]==12 || manualPinPair[2]==13) && manualFuncPair[2]!=4) || ((manualPinPair[2]==18 || manualPinPair[2]==19) && manualFuncPair[2]!=2)) invalid=1
        else add("managed_manual",manualPinPair[2],"","","")
        next
      }
      if(line=="# BEGIN CasaNative GPIO Fan"){
        firstLine=""; endLine=""; if((getline firstLine)<=0 || (getline endLine)<=0){invalid=1; next}; firstLine=clean(firstLine); endLine=clean(endLine)
        if(scope!="all" || endLine!="# END CasaNative GPIO Fan" || firstLine !~ /^dtoverlay=gpio-fan,gpiopin=(12|13|18|19),temp=([4-7][0-9]000),hyst=([5-9]000|1[0-5]000)$/){invalid=1; next}
        split(firstLine,autoParts,","); split(autoParts[2],autoPinPair,"="); split(autoParts[3],autoTempPair,"="); split(autoParts[4],autoHystPair,"=")
        if(autoTempPair[2]<40000 || autoTempPair[2]>75000 || autoHystPair[2]<5000 || autoHystPair[2]>15000 || autoTempPair[2]-autoHystPair[2]<30000) invalid=1
        else add("managed_automatic",autoPinPair[2],"",autoTempPair[2]/1000,autoHystPair[2]/1000)
        next
      }
      if(line=="# BEGIN fan50"){
        firstLine=""; endLine=""; if((getline firstLine)<=0 || (getline endLine)<=0){invalid=1; next}; firstLine=clean(firstLine); endLine=clean(endLine)
        if(scope=="all" && endLine=="# END fan50" && firstLine=="dtoverlay=pwm,pin=18,func=2"){add("external_pwm",18,50,"",""); legacy=1}else invalid=1
        next
      }
      trimmed=line; sub(/^[[:space:]]*/,"",trimmed); sub(/[[:space:]]*$/, "", trimmed)
      if(trimmed=="" || trimmed ~ /^#/) next
      if(trimmed ~ /^include[[:space:]]+/){invalid=1; next}
      if(trimmed ~ /^dtoverlay=pwm-gpio-fan(,|$)/){unsupported=1; next}
      if(trimmed ~ /^dtoverlay=gpio-fan(,|$)/){
        if(trimmed ~ /[[:space:]]/){invalid=1; next}
        configuredPin=12; configuredTemp=55000; configuredHyst=10000; seenPin=0; seenTemp=0; seenHyst=0; bad=0; tokenCount=split(trimmed,gpioTokens,",")
        for(i=2;i<=tokenCount;i++){pairCount=split(gpioTokens[i],gpioPair,"="); if(pairCount!=2)bad=1; else if(gpioPair[1]=="gpiopin"&&!seenPin){configuredPin=gpioPair[2];seenPin=1}else if(gpioPair[1]=="temp"&&!seenTemp){configuredTemp=gpioPair[2];seenTemp=1}else if(gpioPair[1]=="hyst"&&!seenHyst){configuredHyst=gpioPair[2];seenHyst=1}else bad=1}
        if(bad || configuredPin !~ /^(12|13|18|19)$/ || configuredTemp !~ /^[0-9]+$/ || configuredHyst !~ /^[0-9]+$/ || configuredTemp%1000 || configuredHyst%1000 || configuredTemp<40000 || configuredTemp>75000 || configuredHyst<5000 || configuredHyst>15000 || configuredTemp-configuredHyst<30000) invalid=1
        else add("external_gpiofan",configuredPin,"",configuredTemp/1000,configuredHyst/1000)
        next
      }
      if(trimmed ~ /^dtoverlay=pwm(,|$)/){
        if(trimmed !~ /^dtoverlay=pwm,pin=(12|13|18|19),func=(2|4)$/){resource=1; next}
        split(trimmed,pwmTokens,","); split(pwmTokens[2],pwmPinPair,"="); split(pwmTokens[3],pwmFuncPair,"=")
        if(((pwmPinPair[2]==12||pwmPinPair[2]==13)&&pwmFuncPair[2]!=4)||((pwmPinPair[2]==18||pwmPinPair[2]==19)&&pwmFuncPair[2]!=2)) invalid=1
        else add("external_pwm",pwmPinPair[2],"","","")
        next
      }
      if(trimmed ~ /^dtoverlay=(pwm1|pwm-2chan|pwm-gpio|pwm-ir-tx|audremap)(,|$)/ || trimmed ~ /^dtoverlay=.*(hifiberry|i2s).*/ || trimmed ~ /^dtparam=(audio|i2s)=on([,[:space:]]|$)/){resource=1; next}
    }
    END{if(count>1)invalid=1; print state "|" pin "|" duty "|" temp "|" hyst "|" resource "|" unsupported "|" invalid "|" legacy}
  ' "$CFG")"
  oldIFS="$IFS"; IFS='|'; set -- $inspected; IFS="$oldIFS"
  disk_state="$1"; disk_pin="$2"; disk_duty="$3"; disk_temp="$4"; disk_hyst="$5"
  resource_conflict="$6"; unsupported_pwm_gpio="$7"; config_invalid="$8"; legacy_block="$9"
  [ "$config_invalid" = 0 ] || recovery=1
fi

manual_capable=0; pwm_controller_count=0
for chip in /sys/class/pwm/pwmchip*; do
  [ -d "$chip" ] || continue
  [ -r "$chip/npwm" ] && [ -r "$chip/device/of_node/compatible" ] || continue
  compatible="$(tr '\000' '\n' < "$chip/device/of_node/compatible" 2>/dev/null || :)"
  printf '%s\n' "$compatible" | grep -Eq '^(brcm,bcm2835-pwm|brcm,bcm2711-pwm|brcm,bcm2712-pwm|raspberrypi,rp1-pwm)$' || continue
  pwm_controller_count=$((pwm_controller_count + 1))
done
[ "$pwm_controller_count" = 1 ] && manual_capable=1

automatic_capable=0; dtbo=0; module=0; thermal=0
for item in /boot/firmware/overlays/gpio-fan.dtbo /boot/overlays/gpio-fan.dtbo; do [ -r "$item" ] && dtbo=$((dtbo + 1)); done
release="$(uname -r)"
if [ -d /sys/module/gpio_fan ] || grep -Eq '(^|/)gpio-fan\.ko' "/lib/modules/$release/modules.builtin" 2>/dev/null || find "/lib/modules/$release" -type f -name 'gpio-fan.ko*' -print -quit 2>/dev/null | grep -q .; then module=1; fi
for zone in /sys/class/thermal/thermal_zone*; do
  [ -r "$zone/type" ] && [ -r "$zone/temp" ] || continue
  type="$(cat "$zone/type" 2>/dev/null || :)"
  case "$type" in cpu-thermal|cpu_thermal) value="$(cat "$zone/temp" 2>/dev/null || :)"; case "$value" in ''|*[!0-9]*) :;; *) thermal=$((thermal + 1));; esac;; esac
done
[ "$dtbo" = 1 ] && [ "$module" = 1 ] && [ "$thermal" = 1 ] && automatic_capable=1

state_present="$early_state_present"; state_valid=1; journal_present=0; journal_path=''; legacy_backup=0; legacy_backup_count=0
if [ "$stage_recovery" = 1 ]; then
  recovery=1; state_present=1
  if [ "${stage_complete:-0}" = 1 ]; then journal_present=1; journal_path="$STATE_STAGE/journal"; fi
fi
if [ -e "$STATE" ] || [ -L "$STATE" ]; then
  if [ ! -d "$STATE" ] || [ -L "$STATE" ] || [ "$(stat -c '%u:%g:%a' "$STATE" 2>/dev/null || :)" != '0:0:700' ]; then state_valid=0; fi
  if [ "$state_valid" = 1 ]; then
    for item in "$STATE"/*; do
      [ -e "$item" ] || [ -L "$item" ] || continue
      case "${item##*/}" in lock|journal|journal.tmp|legacy-helper|legacy-service|legacy-meta|legacy-helper.tmp|legacy-service.tmp|legacy-meta.tmp) :;; *) state_valid=0;; esac
    done
    regular_root_file "$LOCK" '0:600:1' || state_valid=0
  fi
  journal_count=0
  for candidate in "$STATE/journal" "$STATE/journal.tmp"; do
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
    journal_count=$((journal_count + 1)); journal_path="$candidate"
  done
  if [ "$journal_count" = 1 ]; then
    if [ "$journal_path" = "$STATE/journal" ]; then journal_present=1
    elif canonical_journal_shape "$journal_path"; then journal_present=1; recovery=1
    else regular_root_file "$journal_path" '0:600:1' || state_valid=0; partial_temp_recovery=1; recovery=1; journal_path=''; fi
  elif [ "$journal_count" = 2 ]; then
    if regular_root_file "$STATE/journal" '0:600:1' && regular_root_file "$STATE/journal.tmp" '0:600:1' && [ "$(wc -l < "$STATE/journal" | tr -d ' ')" = 17 ] && [ "$(wc -l < "$STATE/journal.tmp" | tr -d ' ')" = 17 ] && [ "$(sed '2s/^PHASE=.*/PHASE=PHASE/' "$STATE/journal" | /usr/bin/base64 -w0)" = "$(sed '2s/^PHASE=.*/PHASE=PHASE/' "$STATE/journal.tmp" | /usr/bin/base64 -w0)" ]; then journal_present=1; journal_path="$STATE/journal.tmp"; recovery=1
    elif canonical_journal_shape "$STATE/journal" && regular_root_file "$STATE/journal.tmp" '0:600:1'; then journal_present=1; journal_path="$STATE/journal"; partial_temp_recovery=1; recovery=1
    else state_valid=0
    fi
  fi
  backup_count=0
  for item in legacy-helper legacy-service legacy-meta; do { [ -e "$STATE/$item" ] || [ -L "$STATE/$item" ]; } && backup_count=$((backup_count + 1)); done
  legacy_backup_count="$backup_count"
  if [ "$backup_count" = 3 ]; then legacy_backup=1; elif [ "$backup_count" != 0 ]; then legacy_backup=partial; fi
fi
[ "$stage_recovery" = 0 ] || legacy_backup=0
[ "$state_valid" = 1 ] || recovery=1

for item in /usr/local/sbin/casanative-pwm-fan.tmp /etc/default/casanative-pwm-fan.tmp /etc/systemd/system/casanative-pwm-fan.service.tmp "$STATE/legacy-helper.tmp" "$STATE/legacy-service.tmp" "$STATE/legacy-meta.tmp"; do
  [ -e "$item" ] || [ -L "$item" ] || continue
  [ -f "$item" ] && [ ! -L "$item" ] && [ "$(stat -c '%u:%g:%h' "$item" 2>/dev/null || :)" = '0:0:1' ] || exit 75
  case "$(stat -c %a "$item" 2>/dev/null || :)" in 600|644|755) :;; *) exit 75;; esac
  partial_temp_recovery=1; recovery=1
done

helper_ok=0; service_ok=0; defaults_ok=0
if regular_root_file /usr/local/sbin/casanative-pwm-fan '0:755:1' && /usr/bin/printf '%s' '#(expectedHelper)' | /usr/bin/base64 -d | cmp -s - /usr/local/sbin/casanative-pwm-fan; then helper_ok=1; fi
if regular_root_file /etc/systemd/system/casanative-pwm-fan.service '0:644:1' && /usr/bin/printf '%s' '#(expectedService)' | /usr/bin/base64 -d | cmp -s - /etc/systemd/system/casanative-pwm-fan.service; then service_ok=1; fi
default_mode=''; default_pin=''; default_duty=''
if regular_root_file /etc/default/casanative-pwm-fan '0:644:1' && [ "$(wc -l < /etc/default/casanative-pwm-fan | tr -d ' ')" = 3 ]; then
  default_mode="$(sed -n '1s/^MODE=//p' /etc/default/casanative-pwm-fan)"
  default_pin="$(sed -n '2s/^PIN=//p' /etc/default/casanative-pwm-fan)"
  default_duty="$(sed -n '3s/^DUTY_PERCENT=//p' /etc/default/casanative-pwm-fan)"
  case "$default_mode:$default_pin:$default_duty" in manual:12:*|manual:13:*|manual:18:*|manual:19:*|automatic:12:0|automatic:13:0|automatic:18:0|automatic:19:0) defaults_ok=1;; esac
  case "$default_duty" in ''|*[!0-9]*) defaults_ok=0;; *) [ "$default_duty" -le 100 ] || defaults_ok=0;; esac
fi
asset_count=0; { [ -e /usr/local/sbin/casanative-pwm-fan ] || [ -L /usr/local/sbin/casanative-pwm-fan ]; } && asset_count=$((asset_count + 1)); { [ -e /etc/systemd/system/casanative-pwm-fan.service ] || [ -L /etc/systemd/system/casanative-pwm-fan.service ]; } && asset_count=$((asset_count + 1)); { [ -e /etc/default/casanative-pwm-fan ] || [ -L /etc/default/casanative-pwm-fan ]; } && asset_count=$((asset_count + 1))
managed_files=none
if [ "$asset_count" = 0 ] && [ "$state_present" = 0 ]; then managed_files=none
elif [ "$helper_ok" = 1 ] && [ "$service_ok" = 1 ] && [ "$defaults_ok" = 1 ] && [ "$state_valid" = 1 ] && [ "$state_present" = 1 ]; then
  fragment="$(/usr/bin/systemctl show -p FragmentPath --value casanative-pwm-fan.service 2>/dev/null || :)"; load="$(/usr/bin/systemctl show -p LoadState --value casanative-pwm-fan.service 2>/dev/null || :)"; dropins="$(/usr/bin/systemctl show -p DropInPaths --value casanative-pwm-fan.service 2>/dev/null || :)"
  if [ "$fragment" = /etc/systemd/system/casanative-pwm-fan.service ] && [ "$load" = loaded ] && [ -z "$dropins" ]; then managed_files=exact; else managed_files=invalid; recovery=1; fi
else managed_files=invalid; recovery=1
fi

transition=none; journal_valid=0; journal_phase=''; recovery_action=''; transition_kind=''; transition_requirement=''
source_state=''; source_pin=''; source_duty=''; source_temp=''; source_hyst=''
target_state=''; target_pin=''; target_duty=''; target_temp=''; target_hyst=''
source_service=''; target_service=''
if [ "$journal_present" = 1 ] && { [ "$state_valid" = 1 ] || [ "$stage_recovery" = 1 ]; }; then
  J="$journal_path"
  if ! regular_root_file "$J" '0:600:1' || [ "$(wc -l < "$J" | tr -d ' ')" != 17 ]; then recovery=1
  else
    version="$(sed -n '1s/^VERSION=//p' "$J")"; journal_phase="$(sed -n '2s/^PHASE=//p' "$J")"; transition_kind="$(sed -n '3s/^KIND=//p' "$J")"; transition_requirement="$(sed -n '4s/^REQUIREMENT=//p' "$J")"; prepared="$(sed -n '5s/^PREPARED_BOOT_ID=//p' "$J")"
    source_state="$(sed -n '6s/^SOURCE_MODE=//p' "$J")"; source_pin="$(sed -n '7s/^SOURCE_PIN=//p' "$J")"; source_duty="$(sed -n '8s/^SOURCE_DUTY=//p' "$J")"; source_temp="$(sed -n '9s/^SOURCE_TEMP=//p' "$J")"; source_hyst="$(sed -n '10s/^SOURCE_HYST=//p' "$J")"
    target_state="$(sed -n '11s/^TARGET_MODE=//p' "$J")"; target_pin="$(sed -n '12s/^TARGET_PIN=//p' "$J")"; target_duty="$(sed -n '13s/^TARGET_DUTY=//p' "$J")"; target_temp="$(sed -n '14s/^TARGET_TEMP=//p' "$J")"; target_hyst="$(sed -n '15s/^TARGET_HYST=//p' "$J")"
    source_service="$(sed -n '16s/^SOURCE_SERVICE_ENABLED=//p' "$J")"; target_service="$(sed -n '17s/^TARGET_SERVICE_ENABLED=//p' "$J")"
    current_boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || :)"
    journal_valid=1
    if [ "$version" != 2 ] || ! printf '%s\n' "$prepared" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || ! printf '%s\n' "$current_boot" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then recovery=1; journal_valid=0
    else [ "$current_boot" = "$prepared" ] && transition=prepared || transition=bootedAwaitingConfirmation
    fi
    case "$transition_kind" in change|rollback|uninstall) :;; *) recovery=1; journal_valid=0;; esac
    case "$transition_requirement" in reboot|shutdown) :;; *) recovery=1; journal_valid=0;; esac
    case "$journal_phase" in
      prepared) :;;
      cancelling) recovery=1; recovery_action=cancelPreparedChange;;
      finalizing) recovery=1; [ "$transition_kind" = uninstall ] && recovery_action=completeUninstall || recovery_action=finalizePreparedChange;;
      legacyConverting) recovery=1; recovery_action=completeLegacyConversion;;
      legacyRestoring) recovery=1; recovery_action=completeLegacyRestore;;
      legacyDiscarding) recovery=1; recovery_action=completeLegacyDiscard;;
      applying) recovery=1; recovery_action=completeManagedApply;;
      *) recovery=1; journal_valid=0;;
    esac
    case "$source_state" in none|manual|automatic) :;; *) recovery=1; journal_valid=0;; esac
    case "$target_state" in manual|automatic|uninstalled) :;; *) recovery=1; journal_valid=0;; esac
    case "$source_service:$target_service" in 0:0|0:1|1:0|1:1) :;; *) recovery=1; journal_valid=0;; esac
    case "$source_state:$source_pin:$source_duty:$source_temp:$source_hyst" in
      none::::|manual:12:*::|manual:13:*::|manual:18:*::|manual:19:*::|automatic:12::[4-7][0-9]:[5-9]|automatic:12::[4-7][0-9]:1[0-5]|automatic:13::[4-7][0-9]:[5-9]|automatic:13::[4-7][0-9]:1[0-5]|automatic:18::[4-7][0-9]:[5-9]|automatic:18::[4-7][0-9]:1[0-5]|automatic:19::[4-7][0-9]:[5-9]|automatic:19::[4-7][0-9]:1[0-5]) :;; *) journal_valid=0;;
    esac
    case "$target_state:$target_pin:$target_duty:$target_temp:$target_hyst" in
      uninstalled::::|manual:12:*::|manual:13:*::|manual:18:*::|manual:19:*::|automatic:12::[4-7][0-9]:[5-9]|automatic:12::[4-7][0-9]:1[0-5]|automatic:13::[4-7][0-9]:[5-9]|automatic:13::[4-7][0-9]:1[0-5]|automatic:18::[4-7][0-9]:[5-9]|automatic:18::[4-7][0-9]:1[0-5]|automatic:19::[4-7][0-9]:[5-9]|automatic:19::[4-7][0-9]:1[0-5]) :;; *) journal_valid=0;;
    esac
    case "$source_duty:$target_duty:$source_temp:$source_hyst:$target_temp:$target_hyst" in *[!0-9:]* ) journal_valid=0;; esac
    [ -z "$source_duty" ] || [ "$source_duty" -le 100 ] || journal_valid=0
    [ -z "$target_duty" ] || [ "$target_duty" -le 100 ] || journal_valid=0
    if [ "$source_state" = automatic ]; then [ "$source_temp" -ge 40 ] && [ "$source_temp" -le 75 ] && [ "$source_hyst" -ge 5 ] && [ "$source_hyst" -le 15 ] && [ $((source_temp-source_hyst)) -ge 30 ] || journal_valid=0; fi
    if [ "$target_state" = automatic ]; then [ "$target_temp" -ge 40 ] && [ "$target_temp" -le 75 ] && [ "$target_hyst" -ge 5 ] && [ "$target_hyst" -le 15 ] && [ $((target_temp-target_hyst)) -ge 30 ] || journal_valid=0; fi
    case "$transition_kind:$target_state:$source_state" in uninstall:uninstalled:manual|uninstall:uninstalled:automatic|change:manual:none|change:automatic:none|change:manual:manual|change:manual:automatic|change:automatic:manual|change:automatic:automatic|rollback:manual:none|rollback:automatic:none|rollback:uninstalled:manual|rollback:uninstalled:automatic|rollback:manual:manual|rollback:manual:automatic|rollback:automatic:manual|rollback:automatic:automatic) :;; *) journal_valid=0;; esac
    expected_source_service=0; [ "$source_state" = manual ] && expected_source_service=1
    # During prepare, source Manual remains boot-enabled until target boot is
    # confirmed. The final stable state follows the target mode.
    expected_target_service=0; { [ "$source_state" = manual ] || [ "$target_state" = manual ]; } && expected_target_service=1
    [ "$source_service" = "$expected_source_service" ] && [ "$target_service" = "$expected_target_service" ] || journal_valid=0
    if [ "$target_state" = uninstalled ] || { [ "$transition_kind" = rollback ] && [ "$source_state" = none ]; } || { [ "$source_state" != none ] && [ "$source_pin" != "$target_pin" ]; }; then [ "$transition_requirement" = shutdown ] || journal_valid=0; else [ "$transition_requirement" = reboot ] || journal_valid=0; fi
    case "$journal_phase" in
      legacyConverting) [ "$transition_kind:$transition_requirement:$source_state:$target_state:$target_pin:$target_duty" = change:reboot:none:manual:18:50 ] || journal_valid=0;;
      legacyRestoring|legacyDiscarding) [ "$transition_kind:$transition_requirement:$source_state:$source_pin:$source_duty:$target_state:$target_pin:$target_duty" = change:reboot:manual:18:50:manual:18:50 ] || journal_valid=0;;
      applying) [ "$transition_kind:$transition_requirement:$source_state:$target_state" = change:reboot:manual:manual ] && [ "$source_pin" = "$target_pin" ] || journal_valid=0;;
      *)
        if [ "$source_state" != none ] && [ "$target_state" != uninstalled ]; then
          if [ "$source_state" != "$target_state" ]; then
            [ "$source_pin" = "$target_pin" ] || journal_valid=0
          elif [ "$source_state" = manual ]; then
            [ "$source_pin" != "$target_pin" ] && [ "$source_duty" = "$target_duty" ] || journal_valid=0
          elif [ "$source_pin" = "$target_pin" ]; then
            { [ "$source_temp" != "$target_temp" ] || [ "$source_hyst" != "$target_hyst" ]; } || journal_valid=0
          else
            [ "$source_temp" = "$target_temp" ] && [ "$source_hyst" = "$target_hyst" ] || journal_valid=0
          fi
        fi
        ;;
    esac
    [ "$journal_valid" = 1 ] || { recovery=1; recovery_action=''; }
  fi
fi

if [ "$journal_valid" = 1 ] && [ "$journal_phase" = prepared ]; then
  source_disk_matches=0
  case "$source_state" in
    none) [ "$disk_state" = none ] && source_disk_matches=1;;
    manual) [ "$disk_state" = managed_manual ] && [ "$disk_pin" = "$source_pin" ] && source_disk_matches=1;;
    automatic) [ "$disk_state" = managed_automatic ] && [ "$disk_pin" = "$source_pin" ] && [ "$disk_temp" = "$source_temp" ] && [ "$disk_hyst" = "$source_hyst" ] && source_disk_matches=1;;
  esac
  [ "$source_disk_matches" = 0 ] || { recovery=1; recovery_action=cancelPreparedChange; }
fi

# A managed Manual duty is lifecycle state, never boot-config inference.
# Associate it only after the exact defaults/journal records have passed.
if [ "$disk_state" = managed_manual ]; then
  if [ "$transition" != none ] && [ "$target_state" = manual ] && [ "$disk_pin" = "$target_pin" ]; then
    disk_duty="$target_duty"
  elif [ "$transition" = none ] && [ "$default_mode" = manual ] && [ "$disk_pin" = "$default_pin" ]; then
    disk_duty="$default_duty"
  else
    recovery=1
  fi
fi

if [ "$managed_files" = exact ]; then
  service_state="$(/usr/bin/systemctl is-enabled casanative-pwm-fan.service 2>/dev/null || :)"
  if [ "$transition" != none ] && { [ "$journal_phase" = prepared ] || [ "$journal_phase" = cancelling ]; }; then expected_service="$target_service"
  elif [ "$transition" != none ] && [ "$journal_phase" = finalizing ]; then [ "$target_state" = manual ] && expected_service=1 || expected_service=0
  elif [ "$transition" != none ]; then expected_service=either
  elif [ "$disk_state" = managed_manual ]; then expected_service=1
  elif [ "$disk_state" = managed_automatic ]; then expected_service=0
  else expected_service=x
  fi
  case "$expected_service:$service_state" in 1:enabled|0:disabled|either:enabled|either:disabled) :;; *) recovery=1;; esac
fi

legacy=none
legacy_script_ok=0; legacy_service_ok=0
if regular_root_file /usr/local/bin/fan50.sh '0:755:1' && /usr/bin/printf '%s' '#(expectedLegacyHelper)' | /usr/bin/base64 -d | cmp -s - /usr/local/bin/fan50.sh; then legacy_script_ok=1; fi
if regular_root_file /etc/systemd/system/fan50.service '0:644:1' && /usr/bin/printf '%s' '#(expectedLegacyService)' | /usr/bin/base64 -d | cmp -s - /etc/systemd/system/fan50.service; then legacy_service_ok=1; fi
if [ "$legacy_service_ok" = 1 ]; then
  fragment="$(/usr/bin/systemctl show -p FragmentPath --value fan50.service 2>/dev/null || :)"; load="$(/usr/bin/systemctl show -p LoadState --value fan50.service 2>/dev/null || :)"; dropins="$(/usr/bin/systemctl show -p DropInPaths --value fan50.service 2>/dev/null || :)"
  [ "$fragment" = /etc/systemd/system/fan50.service ] && [ "$load" = loaded ] && [ -z "$dropins" ] || legacy_service_ok=0
fi
if [ "$legacy_block" = 1 ] && [ "$legacy_script_ok" = 1 ] && [ "$legacy_service_ok" = 1 ] && [ "$managed_files" = none ]; then legacy=exact
elif [ "$legacy_block" = 1 ] || [ -e /usr/local/bin/fan50.sh ] || [ -L /usr/local/bin/fan50.sh ] || [ -e /etc/systemd/system/fan50.service ] || [ -L /etc/systemd/system/fan50.service ]; then recovery=1
fi
if [ "$legacy_backup" = 1 ]; then
  if regular_root_file "$STATE/legacy-helper" '0:600:1' && regular_root_file "$STATE/legacy-service" '0:600:1' && regular_root_file "$STATE/legacy-meta" '0:600:1' && /usr/bin/printf '%s' '#(expectedLegacyHelper)' | /usr/bin/base64 -d | cmp -s - "$STATE/legacy-helper" && /usr/bin/printf '%s' '#(expectedLegacyService)' | /usr/bin/base64 -d | cmp -s - "$STATE/legacy-service" && grep -Eq '^SERVICE_ENABLED=(0|1)$' "$STATE/legacy-meta" && [ "$(wc -l < "$STATE/legacy-meta" | tr -d ' ')" = 1 ]; then legacy=backup; else recovery=1; fi
fi
if [ "$legacy_backup" = partial ]; then
  if [ -e "$STATE/legacy-helper" ] || [ -L "$STATE/legacy-helper" ]; then regular_root_file "$STATE/legacy-helper" '0:600:1' && /usr/bin/printf '%s' '#(expectedLegacyHelper)' | /usr/bin/base64 -d | cmp -s - "$STATE/legacy-helper" || recovery=1; fi
  if [ -e "$STATE/legacy-service" ] || [ -L "$STATE/legacy-service" ]; then regular_root_file "$STATE/legacy-service" '0:600:1' && /usr/bin/printf '%s' '#(expectedLegacyService)' | /usr/bin/base64 -d | cmp -s - "$STATE/legacy-service" || recovery=1; fi
  if [ -e "$STATE/legacy-meta" ] || [ -L "$STATE/legacy-meta" ]; then regular_root_file "$STATE/legacy-meta" '0:600:1' && grep -Eq '^SERVICE_ENABLED=(0|1)$' "$STATE/legacy-meta" && [ "$(wc -l < "$STATE/legacy-meta" | tr -d ' ')" = 1 ] || recovery=1; fi
  case "$journal_phase" in legacyConverting|legacyRestoring|legacyDiscarding) :;; *) recovery=1; recovery_action='';; esac
fi

live_state=none; live_pin=''; live_duty=''; live_temp=''; live_hyst=''; live_period=''; live_enabled=''; automatic_demand=''
manual_live_count=0; manual_invalid=0
for pwm in /sys/class/pwm/pwmchip*/pwm*; do
  [ -d "$pwm" ] || continue
  case "${pwm##*/}" in pwm0) channel=0;; pwm1) channel=1;; *) manual_invalid=1; continue;; esac
  chip="${pwm%/*}"; [ -r "$chip/device/of_node/compatible" ] || { manual_invalid=1; continue; }
  compatible="$(tr '\000' '\n' < "$chip/device/of_node/compatible" 2>/dev/null || :)"; printf '%s\n' "$compatible" | grep -Eq '^(brcm,bcm2835-pwm|brcm,bcm2711-pwm|brcm,bcm2712-pwm|raspberrypi,rp1-pwm)$' || { manual_invalid=1; continue; }
  period="$(cat "$pwm/period" 2>/dev/null || :)"; duty="$(cat "$pwm/duty_cycle" 2>/dev/null || :)"; enabled="$(cat "$pwm/enable" 2>/dev/null || :)"
  case "$period:$duty:$enabled" in *[!0-9:]*|*::* ) manual_invalid=1; continue;; esac
  [ "$period" = 40000 ] && [ "$duty" -le "$period" ] && { [ "$enabled" = 0 ] || [ "$enabled" = 1 ]; } || { manual_invalid=1; continue; }
  resolved=''; resolved_count=0
  for pins_file in $(find /sys/firmware/devicetree/base -type f -path '*pwm*' -name brcm,pins 2>/dev/null); do
    node="${pins_file%/*}"; [ -r "$node/brcm,function" ] || continue
    phex="$(od -An -tx1 -N4 "$pins_file" 2>/dev/null | tr -d ' \n')"; fhex="$(od -An -tx1 -N4 "$node/brcm,function" 2>/dev/null | tr -d ' \n')"
    case "$phex:$fhex" in 0000000c:00000004) p=12; c=0;; 0000000d:00000004) p=13; c=1;; 00000012:00000002) p=18; c=0;; 00000013:00000002) p=19; c=1;; *) continue;; esac
    [ "$c" = "$channel" ] || continue; resolved="$p"; resolved_count=$((resolved_count + 1))
  done
  [ "$resolved_count" = 1 ] || { manual_invalid=1; continue; }
  manual_live_count=$((manual_live_count + 1)); live_pin="$resolved"; live_period="$period"; live_duty=$((duty * 100 / period)); live_enabled="$enabled"
done

auto_live_count=0; auto_invalid=0; gpio_node=''; auto_bound_device=''; auto_dt_zone=''; auto_dt_trip=''
for node in /sys/firmware/devicetree/base/* /sys/firmware/devicetree/base/*/*; do
  [ -r "$node/compatible" ] || continue
  tr '\000' '\n' < "$node/compatible" 2>/dev/null | grep -qx gpio-fan || continue
  [ "$(tr '\000' '\n' < "$node/status" 2>/dev/null || printf okay)" = okay ] || { auto_invalid=1; continue; }
  [ -r "$node/gpios" ] && [ -r "$node/phandle" ] && [ -r "$node/gpio-fan,speed-map" ] && [ -r "$node/#cooling-cells" ] || { auto_invalid=1; continue; }
  phex="$(od -An -tx1 -N12 "$node/gpios" 2>/dev/null | tr -d ' \n')"; fan_phandle="$(od -An -tx1 -N4 "$node/phandle" 2>/dev/null | tr -d ' \n')"
  [ "${#phex}" = 24 ] && [ "${#fan_phandle}" = 8 ] || { auto_invalid=1; continue; }
  [ "$(od -An -tx1 -N16 "$node/gpio-fan,speed-map" 2>/dev/null | tr -d ' \n')" = 00000000000000000000138800000001 ] && [ "$(od -An -tx1 -N4 "$node/#cooling-cells" 2>/dev/null | tr -d ' \n')" = 00000002 ] || { auto_invalid=1; continue; }
  cell="$(printf '%s' "$phex" | cut -c9-16)"; flags="$(printf '%s' "$phex" | cut -c17-24)"; [ "$flags" = 00000000 ] || { auto_invalid=1; continue; }
  case "$cell" in 0000000c)p=12;;0000000d)p=13;;00000012)p=18;;00000013)p=19;;*)auto_invalid=1;continue;;esac
  bound_count=0; bound_device=''
  for device in /sys/bus/platform/drivers/gpio-fan/*; do
    [ -L "$device/driver" ] && [ -e "$device/of_node" ] || continue
    [ "$(readlink -f "$device/of_node" 2>/dev/null || :)" = "$(readlink -f "$node" 2>/dev/null || :)" ] || continue
    bound_count=$((bound_count + 1)); bound_device="$device"
  done
  [ "$bound_count" = 1 ] || { auto_invalid=1; continue; }
  map_count=0; trip_phandle=''; matched_dt_zone=''
  for cooling in /sys/firmware/devicetree/base/thermal-zones/*/cooling-maps/*; do
    [ -r "$cooling/cooling-device" ] && [ -r "$cooling/trip" ] || continue
    cooling_hex="$(od -An -tx1 "$cooling/cooling-device" 2>/dev/null | tr -d ' \n')"
    [ "${#cooling_hex}" = 24 ] || continue
    [ "$(printf '%s' "$cooling_hex" | cut -c1-8)" = "$fan_phandle" ] || continue
    [ "$(printf '%s' "$cooling_hex" | cut -c9-16)" = 00000001 ] && [ "$(printf '%s' "$cooling_hex" | cut -c17-24)" = 00000001 ] || { auto_invalid=1; continue; }
    trip="$(od -An -tx1 -N4 "$cooling/trip" 2>/dev/null | tr -d ' \n')"; [ "${#trip}" = 8 ] || { auto_invalid=1; continue; }
    map_count=$((map_count + 1)); trip_phandle="$trip"; matched_dt_zone="${cooling%%/cooling-maps/*}"
  done
  [ "$map_count" = 1 ] || { auto_invalid=1; continue; }
  trip_count=0; trip_node=''
  for candidate in /sys/firmware/devicetree/base/thermal-zones/*/trips/*; do
    [ -r "$candidate/phandle" ] || continue
    [ "$(od -An -tx1 -N4 "$candidate/phandle" 2>/dev/null | tr -d ' \n')" = "$trip_phandle" ] || continue
    trip_count=$((trip_count + 1)); trip_node="$candidate"
  done
  [ "$trip_count" = 1 ] && [ -r "$trip_node/temperature" ] && [ -r "$trip_node/hysteresis" ] && [ "$(tr '\000' '\n' < "$trip_node/type" 2>/dev/null || :)" = active ] || { auto_invalid=1; continue; }
  thex="$(od -An -tx1 -N4 "$trip_node/temperature" 2>/dev/null | tr -d ' \n')"; hhex="$(od -An -tx1 -N4 "$trip_node/hysteresis" 2>/dev/null | tr -d ' \n')"
  [ "${#thex}" = 8 ] && [ "${#hhex}" = 8 ] || { auto_invalid=1; continue; }
  t=$((0x$thex)); h=$((0x$hhex)); [ $((t % 1000)) = 0 ] && [ $((h % 1000)) = 0 ] && [ "$t" -ge 40000 ] && [ "$t" -le 75000 ] && [ "$h" -ge 5000 ] && [ "$h" -le 15000 ] && [ $((t-h)) -ge 30000 ] || { auto_invalid=1; continue; }
  auto_live_count=$((auto_live_count + 1)); auto_pin="$p"; auto_temp=$((t/1000)); auto_hyst=$((h/1000)); gpio_node="$node"; auto_bound_device="$bound_device"; auto_dt_zone="$matched_dt_zone"; auto_dt_trip="$trip_node"
done
if [ "$manual_invalid" = 1 ] || [ "$auto_invalid" = 1 ] || [ "$manual_live_count" -gt 1 ] || [ "$auto_live_count" -gt 1 ] || { [ "$manual_live_count" = 1 ] && [ "$auto_live_count" = 1 ]; }; then live_state=invalid
elif [ "$manual_live_count" = 1 ]; then live_state=manual
elif [ "$auto_live_count" = 1 ]; then
  live_state=automatic; live_pin="$auto_pin"; live_temp="$auto_temp"; live_hyst="$auto_hyst"
  demand_count=0; demand_value=''; matched_cooling=''
  for cooling in /sys/class/thermal/cooling_device*; do
    [ -r "$cooling/type" ] && [ -r "$cooling/cur_state" ] && [ -r "$cooling/max_state" ] || continue
    [ "$(cat "$cooling/type" 2>/dev/null || :)" = gpio-fan ] || continue
    [ "$(cat "$cooling/max_state" 2>/dev/null || :)" = 1 ] || { auto_invalid=1; continue; }
    state="$(cat "$cooling/cur_state" 2>/dev/null || :)"; case "$state" in 0)demand_value=off;;1)demand_value=full;;*)auto_invalid=1;continue;;esac
    binding_count=0
    for zone in /sys/class/thermal/thermal_zone*; do
      [ -r "$zone/type" ] || continue
      case "$(cat "$zone/type" 2>/dev/null || :)" in cpu-thermal|cpu_thermal) :;; *) continue;; esac
      for link in "$zone"/cdev*; do
        [ -L "$link" ] || continue
        name="${link##*/}"; case "$name" in cdev[0-9]*) :;; *) continue;; esac
        [ "$(readlink -f "$link" 2>/dev/null || :)" = "$(readlink -f "$cooling" 2>/dev/null || :)" ] || continue
        index="${name#cdev}"; trip_file="$zone/cdev${index}_trip_point"
        [ -r "$trip_file" ] || { auto_invalid=1; continue; }
        trip_index="$(cat "$trip_file" 2>/dev/null || :)"; case "$trip_index" in ''|*[!0-9]*)auto_invalid=1;continue;;esac
        [ -r "$zone/trip_point_${trip_index}_type" ] && [ -r "$zone/trip_point_${trip_index}_temp" ] && [ -r "$zone/trip_point_${trip_index}_hyst" ] || { auto_invalid=1; continue; }
        [ "$(cat "$zone/trip_point_${trip_index}_type" 2>/dev/null || :)" = active ] || continue
        [ "$(cat "$zone/trip_point_${trip_index}_temp" 2>/dev/null || :)" = $((auto_temp * 1000)) ] || continue
        [ "$(cat "$zone/trip_point_${trip_index}_hyst" 2>/dev/null || :)" = $((auto_hyst * 1000)) ] || continue
        binding_count=$((binding_count + 1))
      done
    done
    [ "$binding_count" = 1 ] || { auto_invalid=1; continue; }
    matched_cooling="$cooling"; demand_count=$((demand_count + 1))
  done
  [ "$demand_count" = 1 ] && [ "$auto_invalid" = 0 ] && automatic_demand="$demand_value" || { automatic_demand=unknown; live_state=invalid; }
fi

pigs=none; pigs_path=''; pigpio_version=''; pigpio_pin=''; pigpio_duty=''; pigpio_frequency=''; pigpio_mode=''; pigs_count=0
for candidate in /usr/bin/pigs /usr/local/bin/pigs; do
  [ -e "$candidate" ] || [ -L "$candidate" ] || continue; pigs_count=$((pigs_count + 1))
  if ! regular_root_file "$candidate" "0:$(stat -c %a "$candidate" 2>/dev/null || :):1" || [ ! -x "$candidate" ]; then pigs=invalid; continue; fi
  modebits="$(stat -c %a "$candidate")"; case "$modebits" in ???) :;; *) pigs=invalid; continue;; esac; group="$(printf '%s' "$modebits"|cut -c2)"; other="$(printf '%s' "$modebits"|cut -c3)"; case "$group$other" in *[2367]*) pigs=invalid; continue;; esac
  pigs_path="$candidate"
done
if [ "$pigs_count" -gt 1 ]; then pigs=invalid; pigs_path=''
elif [ "$pigs_count" = 1 ] && [ "$pigs" != invalid ]; then
  version="$("$pigs_path" pigpv 2>/dev/null || :)"; case "$version" in ''|*[!0-9]*) pigs=unreachable;; *)
    if [ "$version" -lt 79 ]; then pigs=unsupported
    else
      pigs=inactive; pigpio_version="$version"
      for pin in 12 13 18 19; do
        case "$pin" in 12|13) expected=4;;18|19) expected=2;;esac
        mode="$("$pigs_path" mg "$pin" 2>/dev/null || :)"; case "$mode" in ''|*[!0-9]*) pigs=unreachable; break;;esac
        [ "$mode" = 0 ] && continue
        if [ "$mode" != "$expected" ]; then
          if [ "$auto_live_count" = 1 ] && [ "$auto_pin" = "$pin" ]; then continue; fi
          pigs=occupied; break
        fi
        duty="$("$pigs_path" gdc "$pin" 2>/dev/null || :)"; frequency="$("$pigs_path" pfg "$pin" 2>/dev/null || :)"; case "$duty:$frequency" in *[!0-9:]*|*::* ) pigs=unreachable; break;;esac
        [ "$duty" -le 1000000 ] && [ "$frequency" = 25000 ] || { pigs=unreachable; break; }
        [ -z "$pigpio_pin" ] || { pigs=ambiguous; pigpio_pin=''; break; }
        pigs=active; pigpio_pin="$pin"; pigpio_duty="$duty"; pigpio_frequency="$frequency"; pigpio_mode="$mode"
      done
    fi;; esac
fi
case "$pigs" in active) :;; inactive) :;; *) pigpio_version=''; pigpio_pin=''; pigpio_duty=''; pigpio_frequency=''; pigpio_mode='';; esac

# Transition phase is live evidence, not a boot-ID inference. A source that
# remains live after an interrupted pre-config write is still cancellable even
# after a power cycle; only an exact target on a different boot is booted.
matches_live_generation() {
  mode="$1"; pin="$2"; duty="$3"; temp="$4"; hyst="$5"
  case "$mode" in
    none|uninstalled) [ "$live_state" = none ];;
    manual) [ "$live_state" = manual ] && [ "$live_pin" = "$pin" ] && [ "$live_duty" = "$duty" ] && [ "$live_period" = 40000 ] && [ "$live_enabled" = 1 ];;
    automatic) [ "$live_state" = automatic ] && [ "$live_pin" = "$pin" ] && [ "$live_temp" = "$temp" ] && [ "$live_hyst" = "$hyst" ];;
    *) return 1;;
  esac
}
matches_disk_generation() {
  mode="$1"; pin="$2"; temp="$3"; hyst="$4"
  case "$mode" in
    none|uninstalled) [ "$disk_state" = none ];;
    manual) [ "$disk_state" = managed_manual ] && [ "$disk_pin" = "$pin" ];;
    automatic) [ "$disk_state" = managed_automatic ] && [ "$disk_pin" = "$pin" ] && [ "$disk_temp" = "$temp" ] && [ "$disk_hyst" = "$hyst" ];;
    *) return 1;;
  esac
}
if [ "$journal_valid" = 1 ]; then
  source_live=0; target_live=0; source_disk=0; target_disk=0
  matches_live_generation "$source_state" "$source_pin" "$source_duty" "$source_temp" "$source_hyst" && source_live=1 || :
  matches_live_generation "$target_state" "$target_pin" "$target_duty" "$target_temp" "$target_hyst" && target_live=1 || :
  matches_disk_generation "$source_state" "$source_pin" "$source_temp" "$source_hyst" && source_disk=1 || :
  matches_disk_generation "$target_state" "$target_pin" "$target_temp" "$target_hyst" && target_disk=1 || :
  current_boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || :)"
  case "$journal_phase" in
    legacyConverting|legacyRestoring|legacyDiscarding)
      transition=prepared
      ;;
    applying)
      if [ "$source_live" = 1 ] || [ "$target_live" = 1 ]; then transition=prepared
      else transition=none; recovery=1; recovery_action=''; fi
      ;;
    *)
      if [ "$target_live" = 1 ] && [ "$target_disk" = 1 ] && [ "$current_boot" != "$prepared" ]; then
        transition=bootedAwaitingConfirmation
      elif [ "$source_live" = 1 ] && { [ "$source_disk" = 1 ] || [ "$target_disk" = 1 ]; }; then
        transition=prepared
      else
        transition=none; recovery=1; recovery_action=''
      fi
      ;;
  esac
  case "$journal_phase:$transition" in
    prepared:prepared)
      if [ "$recovery" = 1 ]; then
        [ "$transition_kind" = rollback ] && recovery_action=completeRollbackPreparation || recovery_action=cancelPreparedChange
      else
        recovery_action=''
      fi
      ;;
    prepared:bootedAwaitingConfirmation) [ "$recovery" = 1 ] && { [ "$transition_kind" = uninstall ] && recovery_action=completeUninstall || recovery_action=finalizePreparedChange; } || recovery_action='';;
    cancelling:prepared) recovery=1; recovery_action=cancelPreparedChange;;
    cancelling:bootedAwaitingConfirmation) recovery=1; [ "$transition_kind" = uninstall ] && recovery_action=completeUninstall || recovery_action=finalizePreparedChange;;
    finalizing:bootedAwaitingConfirmation) recovery=1; [ "$transition_kind" = uninstall ] && recovery_action=completeUninstall || recovery_action=finalizePreparedChange;;
    applying:prepared) recovery=1; recovery_action=completeManagedApply;;
    legacyConverting:prepared) recovery=1; recovery_action=completeLegacyConversion;;
    legacyRestoring:prepared) recovery=1; recovery_action=completeLegacyRestore;;
    legacyDiscarding:prepared) recovery=1; recovery_action=completeLegacyDiscard;;
    *) recovery=1; recovery_action='';;
  esac
fi
if { [ "$stage_recovery" = 1 ] && [ "${stage_complete:-0}" = 0 ]; } || [ "$partial_temp_recovery" = 1 ]; then
  recovery=1; transition=none; journal_phase=removing; recovery_action=completeStateCleanup
  transition_kind=''; transition_requirement=''
  source_state=''; source_pin=''; source_duty=''; source_temp=''; source_hyst=''
  target_state=''; target_pin=''; target_duty=''; target_temp=''; target_hyst=''
fi
if [ "$removal_recovery" = 1 ]; then
  recovery=1; transition=none; journal_phase=removing; recovery_action=completeStateCleanup
  transition_kind=''; transition_requirement=''
  source_state=''; source_pin=''; source_duty=''; source_temp=''; source_hyst=''
  target_state=''; target_pin=''; target_duty=''; target_temp=''; target_hyst=''
fi

printf '%s\n' CASANATIVE_PWM_FAN_V3
emit config "$config"
emit resource_conflict "$resource_conflict"
emit unsupported_pwm_gpio "$unsupported_pwm_gpio"
emit manual_capable "$manual_capable"
emit automatic_capable "$automatic_capable"
emit managed_files "$managed_files"
emit disk_state "$disk_state"
emit disk_pin "$disk_pin"
emit disk_duty "$disk_duty"
emit disk_temp "$disk_temp"
emit disk_hyst "$disk_hyst"
emit live_state "$live_state"
emit live_pin "$live_pin"
emit live_duty "$live_duty"
emit live_temp "$live_temp"
emit live_hyst "$live_hyst"
emit live_period "$live_period"
emit live_enabled "$live_enabled"
emit automatic_demand "$automatic_demand"
emit transition "$transition"
emit journal_phase "$journal_phase"
emit recovery_action "$recovery_action"
emit transition_kind "$transition_kind"
emit transition_requirement "$transition_requirement"
emit source_state "$source_state"
emit source_pin "$source_pin"
emit source_duty "$source_duty"
emit source_temp "$source_temp"
emit source_hyst "$source_hyst"
emit target_state "$target_state"
emit target_pin "$target_pin"
emit target_duty "$target_duty"
emit target_temp "$target_temp"
emit target_hyst "$target_hyst"
emit legacy "$legacy"
emit recovery "$recovery"
emit pigs "$pigs"
emit pigs_path "$pigs_path"
emit pigpio_version "$pigpio_version"
emit pigpio_pin "$pigpio_pin"
emit pigpio_duty "$pigpio_duty"
emit pigpio_frequency "$pigpio_frequency"
emit pigpio_mode "$pigpio_mode"
"""#
    }()

    static func defaultFile(
        for configuration: PWMFanConfiguration
    ) -> String {
        switch configuration {
        case let .manual(value):
            "MODE=manual\nPIN=\(value.pin.rawValue)\nDUTY_PERCENT=\(value.dutyPercent)\n"
        case let .automatic(value):
            "MODE=automatic\nPIN=\(value.pin.rawValue)\nDUTY_PERCENT=0\n"
        }
    }

    static func block(
        for configuration: PWMFanConfiguration
    ) -> String {
        switch configuration {
        case let .manual(value):
            """
            # BEGIN CasaNative PWM Fan
            dtoverlay=pwm,pin=\(value.pin.rawValue),func=\(value.pin.function)
            # END CasaNative PWM Fan
            """
        case let .automatic(value):
            """
            # BEGIN CasaNative GPIO Fan
            dtoverlay=gpio-fan,gpiopin=\(value.pin.rawValue),temp=\(value.turnOnCelsius * 1_000),hyst=\(value.hysteresisCelsius * 1_000)
            # END CasaNative GPIO Fan
            """
        }
    }

    static func fields(
        for configuration: PWMFanConfiguration?
    ) -> (mode: String, pin: String, duty: String, temp: String, hyst: String) {
        guard let configuration else {
            return ("none", "", "", "", "")
        }
        switch configuration {
        case let .manual(value):
            return (
                "manual", "\(value.pin.rawValue)",
                "\(value.dutyPercent)", "", ""
            )
        case let .automatic(value):
            return (
                "automatic", "\(value.pin.rawValue)", "",
                "\(value.turnOnCelsius)", "\(value.hysteresisCelsius)"
            )
        }
    }

    static func journal(
        source: PWMFanConfiguration?,
        target: PWMFanTransitionTarget,
        kind: PWMFanTransitionKind,
        requirement: PWMFanTransitionRequirement,
        phase: String = "prepared",
        bootIDExpression: String = "$boot_id"
    ) -> String {
        let old = fields(for: source)
        let new = fields(for: target.configuration)
        let targetMode = target.isUninstall ? "uninstalled" : new.mode
        let kindValue: String = switch kind {
        case .configurationChange: "change"
        case .rollback: "rollback"
        case .uninstall: "uninstall"
        }
        let requirementValue = requirement == .reboot ? "reboot" : "shutdown"
        let sourceEnabled = source?.mode == .manual ? "1" : "0"
        let targetEnabled: Bool = source?.mode == .manual
            || target.configuration?.mode == .manual
        return """
        VERSION=2
        PHASE=\(phase)
        KIND=\(kindValue)
        REQUIREMENT=\(requirementValue)
        PREPARED_BOOT_ID=\(bootIDExpression)
        SOURCE_MODE=\(old.mode)
        SOURCE_PIN=\(old.pin)
        SOURCE_DUTY=\(old.duty)
        SOURCE_TEMP=\(old.temp)
        SOURCE_HYST=\(old.hyst)
        TARGET_MODE=\(targetMode)
        TARGET_PIN=\(new.pin)
        TARGET_DUTY=\(new.duty)
        TARGET_TEMP=\(new.temp)
        TARGET_HYST=\(new.hyst)
        SOURCE_SERVICE_ENABLED=\(sourceEnabled)
        TARGET_SERVICE_ENABLED=\(targetEnabled ? "1" : "0")
        """ + "\n"
    }

    static func provisionScript(
        configuration: PWMFanConfiguration,
        requirement: PWMFanTransitionRequirement
    ) -> String {
        let target = PWMFanTransitionTarget.configuration(configuration)
        let journalValue = journal(
            source: nil,
            target: target,
            kind: .configurationChange,
            requirement: requirement,
            bootIDExpression: "BOOT_ID"
        )
        let targetBlock = block(for: configuration)
        let targetDefault = defaultFile(for: configuration)
        return mutationCommon + "\nresolve_config\n" + provisionPreflight(for: configuration) + "\n" + """
        [ ! -e "$STATE" ] && [ ! -L "$STATE" ]
        [ ! -e "$HELPER" ] && [ ! -L "$HELPER" ]
        [ ! -e "$DEFAULT" ] && [ ! -L "$DEFAULT" ]
        [ ! -e "$SERVICE" ] && [ ! -L "$SERVICE" ]
        [ ! -e /usr/local/bin/fan50.sh ] && [ ! -L /usr/local/bin/fan50.sh ]
        [ ! -e /etc/systemd/system/fan50.service ] && [ ! -L /etc/systemd/system/fan50.service ]
        create_state_with_journal '\(base64(journalValue))'
        exec 9<>"$LOCK"
        flock -x -w 3 9
        resolve_config
        \(provisionPreflight(for: configuration))
        rollback_new() {
          result="$?"
          rm -f "$CFG_TMP" "$HELPER.tmp" "$DEFAULT.tmp" "$SERVICE.tmp" "$STATE/journal.tmp"
          config_has_target=0
          find_exact_block '\(targetBlock.split(separator: "\n").first!)' '\(base64(targetBlock + "\n"))' >/dev/null 2>&1 && config_has_target=1 || :
          if [ "$result" -ne 0 ] && [ "$config_has_target" = 0 ]; then
            /usr/bin/systemctl disable casanative-pwm-fan.service >/dev/null 2>&1 || :
            rm -f "$HELPER" "$DEFAULT" "$SERVICE"
            /usr/bin/systemctl daemon-reload >/dev/null 2>&1 || :
            retire_state_atomically
          fi
          exit "$result"
        }
        trap rollback_new EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        write_fixed '\(base64(helper))' "$HELPER" 0755
        write_fixed '\(base64(service))' "$SERVICE" 0644
        write_fixed '\(base64(targetDefault))' "$DEFAULT" 0644
        /usr/bin/systemctl daemon-reload
        effective_unit_exact casanative-pwm-fan.service /etc/systemd/system/casanative-pwm-fan.service
        \(
            configuration.mode == .manual
                ? "/usr/bin/systemctl enable casanative-pwm-fan.service >/dev/null"
                : "/usr/bin/systemctl disable casanative-pwm-fan.service >/dev/null"
        )
        publish_append '\(base64(targetBlock))'
        sync -f "$CFG"
        sync -f "${CFG%/*}"
        trap - EXIT HUP INT TERM
        """
    }

    static func prepareConfigurationChangeScript(
        source: PWMFanConfiguration,
        target: PWMFanConfiguration,
        requirement: PWMFanTransitionRequirement,
        kind: PWMFanTransitionKind
    ) -> String {
        transitionScript(
            source: source,
            target: .configuration(target),
            requirement: requirement,
            kind: kind
        )
    }

    static func prepareUninstallScript(
        source: PWMFanConfiguration
    ) -> String {
        transitionScript(
            source: source,
            target: .uninstalled,
            requirement: .fullShutdown,
            kind: .uninstall
        )
    }

    static func prepareRollbackScript(
        transition: PWMFanTransitionState
    ) -> String {
        rollbackTransitionScript(originalTransition: transition)
    }

    static func cancelPreparedChangeScript(
        transition: PWMFanTransitionState
    ) -> String {
        let sourceBlock = transition.source.map(block(for:))
        let targetBlock = transition.target.configuration.map(block(for:))
        let sourceDefault = transition.source.map(defaultFile(for:))
        let guardScript = transition.source == nil
            ? partialCleanupStateGuard(
                expectedDefault: transition.target.configuration
            )
            : stateGuard(
                defaultConfiguration: transition.source,
                allowJournal: true,
                allowLegacyBackup:
                    transition.source?.pin == transition.target.configuration?.pin,
                alternateDefaultConfiguration: transition.target.configuration
            )
        return mutationCommon + "\n" + guardScript + "\n" + journalGuard(
            transition: transition,
            sameBoot: nil,
            recoveryPhase: "cancelling"
        ) + "\n" + liveGuard(for: transition.source) + "\n" + """
        \(eitherGenerationGuard(source: sourceBlock, target: targetBlock))
        cleanup_cancel() {
          result="$?"
          rm -f "$CFG_TMP" "$DEFAULT.tmp"
          exit "$result"
        }
        trap cleanup_cancel EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        [ "$actual_phase" = cancelling ] || rewrite_journal_phase cancelling
        effective_unit_exact casanative-pwm-fan.service /etc/systemd/system/casanative-pwm-fan.service
        \(
            sourceDefault.map { "write_fixed '\(base64($0))' \"$DEFAULT\" 0644" }
                ?? "true"
        )
        \(
            transition.source == nil
                ? "true"
                : transition.source?.mode == .manual
                    || transition.target.configuration?.mode == .manual
                    ? "/usr/bin/systemctl enable casanative-pwm-fan.service >/dev/null"
                    : "/usr/bin/systemctl disable casanative-pwm-fan.service >/dev/null"
        )
        \(idempotentReplacement(from: targetBlock, to: sourceBlock))
        sync -f "$CFG"; sync -f "${CFG%/*}"
        \(
            transition.source == nil
                ? "if [ -e \"$SERVICE\" ] || [ -L \"$SERVICE\" ]; then regular_root_file \"$SERVICE\" '0:644:1'; compare_encoded '\(base64(service))' \"$SERVICE\"; /usr/bin/systemctl disable casanative-pwm-fan.service >/dev/null; fi"
                : transition.source?.mode == .manual
                    ? "/usr/bin/systemctl enable casanative-pwm-fan.service >/dev/null"
                    : "/usr/bin/systemctl disable casanative-pwm-fan.service >/dev/null"
        )
        \(
            transition.source == nil ? removeFreshInstallShell : "true"
        )
        \(transition.source == nil ? "retire_state_atomically" : "rm -f \"$STATE/journal\"; sync -f \"$STATE\"")
        trap - EXIT HUP INT TERM
        """
    }

    static func finalizePreparedChangeScript(
        transition: PWMFanTransitionState
    ) -> String {
        let targetConfiguration = transition.target.configuration
        let targetBlock = targetConfiguration.map(block(for:))
        let targetDefault = targetConfiguration.map(defaultFile(for:))
        let cleanupState: String
        if transition.target.isUninstall {
            cleanupState = "retire_state_atomically"
        } else {
            cleanupState = """
            rm -f "$STATE/journal"
            sync -f "$STATE"
            """
        }
        let guardScript = transition.target.isUninstall
            ? partialCleanupStateGuard(expectedDefault: transition.source)
            : stateGuard(
                defaultConfiguration: transition.source ?? targetConfiguration,
                allowJournal: true,
                allowLegacyBackup:
                    transition.source?.pin == targetConfiguration?.pin,
                alternateDefaultConfiguration: targetConfiguration
            )
        return mutationCommon + "\n" + guardScript + "\n" + journalGuard(
            transition: transition,
            sameBoot: false,
            recoveryPhase: "finalizing"
        ) + "\n" + """
        \(
            targetBlock.map { exactBlockGuard(block: $0) }
                ?? absentOwnedBlockGuard
        )
        \(
            liveGuard(for: targetConfiguration)
        )
        [ "$actual_phase" = finalizing ] || rewrite_journal_phase finalizing
        effective_unit_exact casanative-pwm-fan.service /etc/systemd/system/casanative-pwm-fan.service
        \(
            targetDefault.map { "write_fixed '\(base64($0))' \"$DEFAULT\" 0644" }
                ?? "true"
        )
        \(
            targetConfiguration == nil
                ? "if [ -e \"$SERVICE\" ] || [ -L \"$SERVICE\" ]; then regular_root_file \"$SERVICE\" '0:644:1'; compare_encoded '\(base64(service))' \"$SERVICE\"; /usr/bin/systemctl disable casanative-pwm-fan.service >/dev/null; fi"
                : targetConfiguration?.mode == .manual
                    ? "/usr/bin/systemctl enable casanative-pwm-fan.service >/dev/null"
                    : "/usr/bin/systemctl disable casanative-pwm-fan.service >/dev/null"
        )
        final_service_state="$(/usr/bin/systemctl is-enabled casanative-pwm-fan.service 2>/dev/null || :)"
        \(targetConfiguration == nil ? "case \"$final_service_state\" in disabled|not-found) :;; *) exit 75;; esac" : targetConfiguration?.mode == .manual ? "[ \"$final_service_state\" = enabled ]" : "[ \"$final_service_state\" = disabled ]")
        \(
            transition.target.isUninstall ? removeFinalizedInstallShell : "true"
        )
        \(cleanupState)
        """
    }

    static func convertExactLegacyFan50Script() -> String {
        let configuration = PWMFanConfiguration.manual(
            .defaultConfiguration(pin: .gpio18)
        )
        let targetBlock = block(for: configuration)
        let targetDefault = defaultFile(for: configuration)
        let legacyBlock = "# BEGIN fan50\ndtoverlay=pwm,pin=18,func=2\n# END fan50"
        let conversionJournal = journal(
            source: nil,
            target: .configuration(configuration),
            kind: .configurationChange,
            requirement: .reboot,
            phase: "legacyConverting",
            bootIDExpression: "BOOT_ID"
        )
        return mutationCommon + "\nresolve_config\n" + """
        if [ -d "$STATE" ]; then
          [ ! -L "$STATE" ] && [ "$(stat -c '%u:%g:%a' "$STATE")" = '0:0:700' ]
          regular_root_file "$LOCK" '0:600:1'; exec 9<>"$LOCK"; flock -x -w 3 9
          adopt_journal_temp
          recover_config_temp
          recover_fixed_temp "$HELPER" 0755 '\(base64(helper))'
          recover_fixed_temp "$SERVICE" 0644 '\(base64(service))'
          recover_fixed_temp "$DEFAULT" 0644 '\(base64(targetDefault))'
          recover_fixed_temp "$STATE/legacy-helper" 0600 '\(base64(legacyHelper))'
          recover_fixed_temp "$STATE/legacy-service" 0600 '\(base64(legacyService))'
          recover_legacy_meta_temp
          resolve_config
          regular_root_file "$STATE/journal" '0:600:1'
          normalized="$(sed '5s/^PREPARED_BOOT_ID=.*/PREPARED_BOOT_ID=BOOT_ID/' "$STATE/journal" | /usr/bin/base64 -w0)"
          [ "$normalized" = '\(base64(conversionJournal))' ]
          if [ -e "$STATE/legacy-helper" ] || [ -L "$STATE/legacy-helper" ]; then regular_root_file "$STATE/legacy-helper" '0:600:1'; compare_encoded '\(base64(legacyHelper))' "$STATE/legacy-helper"; else regular_root_file /usr/local/bin/fan50.sh '0:755:1'; compare_encoded '\(base64(legacyHelper))' /usr/local/bin/fan50.sh; copy_backup /usr/local/bin/fan50.sh "$STATE/legacy-helper"; fi
          effective_unit_exact fan50.service /etc/systemd/system/fan50.service
          if [ -e "$STATE/legacy-service" ] || [ -L "$STATE/legacy-service" ]; then regular_root_file "$STATE/legacy-service" '0:600:1'; compare_encoded '\(base64(legacyService))' "$STATE/legacy-service"; else regular_root_file /etc/systemd/system/fan50.service '0:644:1'; compare_encoded '\(base64(legacyService))' /etc/systemd/system/fan50.service; copy_backup /etc/systemd/system/fan50.service "$STATE/legacy-service"; fi
          if [ ! -e "$STATE/legacy-meta" ] && [ ! -L "$STATE/legacy-meta" ]; then legacy_state="$(/usr/bin/systemctl is-enabled fan50.service 2>/dev/null || :)"; case "$legacy_state" in enabled) legacy_enabled=1;;disabled)legacy_enabled=0;;*)exit 75;;esac; write_fixed "$(printf 'SERVICE_ENABLED=%s\n' "$legacy_enabled" | /usr/bin/base64 -w0)" "$STATE/legacy-meta" 0600; fi
          verify_legacy_backups
          ensure_backup_copy "$STATE/legacy-helper" /usr/local/bin/fan50.sh 0755
          ensure_backup_copy "$STATE/legacy-service" /etc/systemd/system/fan50.service 0644
          if [ -e "$HELPER" ] || [ -L "$HELPER" ]; then regular_root_file "$HELPER" '0:755:1'; compare_encoded '\(base64(helper))' "$HELPER"; else write_fixed '\(base64(helper))' "$HELPER" 0755; fi
          if [ -e "$SERVICE" ] || [ -L "$SERVICE" ]; then regular_root_file "$SERVICE" '0:644:1'; compare_encoded '\(base64(service))' "$SERVICE"; else write_fixed '\(base64(service))' "$SERVICE" 0644; fi
          if [ -e "$DEFAULT" ] || [ -L "$DEFAULT" ]; then regular_root_file "$DEFAULT" '0:644:1'; compare_encoded '\(base64(targetDefault))' "$DEFAULT"; else write_fixed '\(base64(targetDefault))' "$DEFAULT" 0644; fi
          /usr/bin/systemctl daemon-reload
          effective_unit_exact casanative-pwm-fan.service /etc/systemd/system/casanative-pwm-fan.service
          effective_unit_exact fan50.service /etc/systemd/system/fan50.service
          if block_start="$(find_exact_block '# BEGIN fan50' '\(base64(legacyBlock + "\n"))')"; then
            publish_replace "$block_start" '\(base64(targetBlock))'; sync -f "$CFG"; sync -f "${CFG%/*}"
          else
          \(exactBlockGuard(block: targetBlock))
          fi
          /usr/bin/systemctl enable casanative-pwm-fan.service >/dev/null
          /usr/bin/systemctl disable fan50.service >/dev/null
          { [ ! -e /usr/local/bin/fan50.sh ] && [ ! -L /usr/local/bin/fan50.sh ]; } || { regular_root_file /usr/local/bin/fan50.sh '0:755:1'; compare_encoded '\(base64(legacyHelper))' /usr/local/bin/fan50.sh; rm -f /usr/local/bin/fan50.sh; }
          { [ ! -e /etc/systemd/system/fan50.service ] && [ ! -L /etc/systemd/system/fan50.service ]; } || { regular_root_file /etc/systemd/system/fan50.service '0:644:1'; compare_encoded '\(base64(legacyService))' /etc/systemd/system/fan50.service; rm -f /etc/systemd/system/fan50.service; }
          /usr/bin/systemctl daemon-reload
          rm -f "$STATE/journal"; sync -f "$STATE"
          exit 0
        fi
        [ ! -e "$STATE" ] && [ ! -L "$STATE" ]
        [ ! -e "$HELPER" ] && [ ! -L "$HELPER" ] && [ ! -e "$DEFAULT" ] && [ ! -L "$DEFAULT" ] && [ ! -e "$SERVICE" ] && [ ! -L "$SERVICE" ]
        regular_root_file /usr/local/bin/fan50.sh '0:755:1'
        regular_root_file /etc/systemd/system/fan50.service '0:644:1'
        compare_encoded '\(base64(legacyHelper))' /usr/local/bin/fan50.sh
        compare_encoded '\(base64(legacyService))' /etc/systemd/system/fan50.service
        \(exactBlockGuard(block: legacyBlock))
        verify_manual_live 18 50
        verify_no_pigpio
        legacy_enabled=0
        legacy_state="$(/usr/bin/systemctl is-enabled fan50.service 2>/dev/null || :)"
        case "$legacy_state" in enabled) legacy_enabled=1;; disabled) legacy_enabled=0;; *) exit 75;; esac
        create_state_with_journal '\(base64(conversionJournal))'
        exec 9<>"$LOCK"; flock -x -w 3 9
        resolve_config
        \(exactBlockGuard(block: legacyBlock))
        cleanup_legacy() {
          result="$?"
          rm -f "$CFG_TMP" "$HELPER.tmp" "$DEFAULT.tmp" "$SERVICE.tmp" "$STATE/journal.tmp" "$STATE/legacy-helper.tmp" "$STATE/legacy-service.tmp" "$STATE/legacy-meta.tmp"
          exit "$result"
        }
        trap cleanup_legacy EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        copy_backup /usr/local/bin/fan50.sh "$STATE/legacy-helper"
        copy_backup /etc/systemd/system/fan50.service "$STATE/legacy-service"
        write_fixed "$(/usr/bin/printf 'SERVICE_ENABLED=%s\n' "$legacy_enabled" | /usr/bin/base64 -w0)" "$STATE/legacy-meta" 0600
        write_fixed '\(base64(helper))' "$HELPER" 0755
        write_fixed '\(base64(service))' "$SERVICE" 0644
        write_fixed '\(base64(targetDefault))' "$DEFAULT" 0644
        # Preserve legacy artifacts/service until the managed boot block is durable.
        /usr/bin/systemctl daemon-reload
        effective_unit_exact casanative-pwm-fan.service /etc/systemd/system/casanative-pwm-fan.service
        effective_unit_exact fan50.service /etc/systemd/system/fan50.service
        /usr/bin/systemctl enable casanative-pwm-fan.service >/dev/null
        \(configReplacement(from: legacyBlock, to: targetBlock))
        sync -f "$CFG"; sync -f "${CFG%/*}"
        /usr/bin/systemctl disable fan50.service >/dev/null
        rm -f /usr/local/bin/fan50.sh /etc/systemd/system/fan50.service
        /usr/bin/systemctl daemon-reload
        rm -f "$STATE/journal"; sync -f "$STATE"
        trap - EXIT HUP INT TERM
        """
    }

    static func resolveLegacyBackupScript(
        _ resolution: PWMFanLegacyBackupResolution
    ) -> String {
        let managed = PWMFanConfiguration.manual(
            .defaultConfiguration(pin: .gpio18)
        )
        let managedBlock = block(for: managed)
        let legacyBlock = "# BEGIN fan50\ndtoverlay=pwm,pin=18,func=2\n# END fan50"
        let initialGuard = stateGuard(
            defaultConfiguration: managed,
            allowJournal: false,
            allowLegacyBackup: true
        )
        let phase = resolution == .restore
            ? "legacyRestoring" : "legacyDiscarding"
        let phaseRecord = journal(
            source: managed,
            target: .configuration(managed),
            kind: .configurationChange,
            requirement: .reboot,
            phase: phase,
            bootIDExpression: "BOOT_ID"
        )
        let resumeGuard = partialCleanupStateGuard(
            expectedDefault: managed,
            allowLegacyBackup: true
        ) + "\n" + """
        actual_phase="$(sed -n '2s/^PHASE=//p' "$STATE/journal")"
        [ "$actual_phase" = \(phase) ]
        normalized="$(sed '5s/^PREPARED_BOOT_ID=.*/PREPARED_BOOT_ID=BOOT_ID/' "$STATE/journal" | /usr/bin/base64 -w0)"
        [ "$normalized" = '\(base64(phaseRecord))' ]
        prepared="$(sed -n '5s/^PREPARED_BOOT_ID=//p' "$STATE/journal")"
        printf '%s\n' "$prepared" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        """
        let phaseEntry = """
        if [ -e "$STATE/journal" ] || [ -L "$STATE/journal" ] || [ -e "$STATE/journal.tmp" ] || [ -L "$STATE/journal.tmp" ]; then
          \(resumeGuard)
        else
          \(initialGuard)
          verify_legacy_backups
          write_journal '\(base64(phaseRecord))'
        fi
        """
        switch resolution {
        case .discard:
            return mutationCommon + "\n" + phaseEntry + "\n" + """
            \(exactBlockGuard(block: managedBlock))
            verify_manual_live 18 50
            verify_no_pigpio
            for item in legacy-helper legacy-service legacy-meta; do
              path="$STATE/$item"
              [ ! -e "$path" ] && [ ! -L "$path" ] || { regular_root_file "$path" '0:600:1'; rm -f "$path"; }
            done
            rm -f "$STATE/journal"
            sync -f "$STATE"
            """
        case .restore:
            return mutationCommon + "\n" + phaseEntry + "\n" + """
            recover_fixed_temp /usr/local/bin/fan50.sh 0755 '\(base64(legacyHelper))'
            recover_fixed_temp /etc/systemd/system/fan50.service 0644 '\(base64(legacyService))'
            legacy_enabled=''
            if [ -e "$STATE/legacy-meta" ] || [ -L "$STATE/legacy-meta" ]; then
              regular_root_file "$STATE/legacy-meta" '0:600:1'
              legacy_enabled="$(sed -n 's/^SERVICE_ENABLED=//p' "$STATE/legacy-meta")"
              case "$legacy_enabled" in 0|1) :;; *) exit 75;; esac
            fi
            cleanup_restore() { result="$?"; rm -f "$CFG_TMP" /usr/local/bin/fan50.sh.tmp /etc/systemd/system/fan50.service.tmp; exit "$result"; }
            trap cleanup_restore EXIT
            trap 'exit 129' HUP
            trap 'exit 130' INT
            trap 'exit 143' TERM
            \(eitherGenerationGuard(source: managedBlock, target: legacyBlock))
            verify_manual_live 18 50
            verify_no_pigpio
            if [ -e "$STATE/legacy-helper" ] || [ -L "$STATE/legacy-helper" ]; then ensure_backup_copy "$STATE/legacy-helper" /usr/local/bin/fan50.sh 0755; else regular_root_file /usr/local/bin/fan50.sh '0:755:1'; compare_encoded '\(base64(legacyHelper))' /usr/local/bin/fan50.sh; fi
            if [ -e "$STATE/legacy-service" ] || [ -L "$STATE/legacy-service" ]; then ensure_backup_copy "$STATE/legacy-service" /etc/systemd/system/fan50.service 0644; else regular_root_file /etc/systemd/system/fan50.service '0:644:1'; compare_encoded '\(base64(legacyService))' /etc/systemd/system/fan50.service; fi
            /usr/bin/systemctl daemon-reload
            effective_unit_exact fan50.service /etc/systemd/system/fan50.service
            if [ -e "$SERVICE" ] || [ -L "$SERVICE" ]; then effective_unit_exact casanative-pwm-fan.service /etc/systemd/system/casanative-pwm-fan.service; fi
            if [ -n "$legacy_enabled" ]; then [ "$legacy_enabled" = 1 ] && /usr/bin/systemctl enable fan50.service >/dev/null || /usr/bin/systemctl disable fan50.service >/dev/null; else legacy_state="$(/usr/bin/systemctl is-enabled fan50.service 2>/dev/null || :)"; case "$legacy_state" in enabled|disabled) :;; *) exit 75;; esac; fi
            if [ -e "$SERVICE" ] || [ -L "$SERVICE" ]; then regular_root_file "$SERVICE" '0:644:1'; compare_encoded '\(base64(service))' "$SERVICE"; /usr/bin/systemctl disable casanative-pwm-fan.service >/dev/null; fi
            \(idempotentReplacement(from: managedBlock, to: legacyBlock))
            sync -f "$CFG"; sync -f "${CFG%/*}"
            if [ -e "$HELPER" ] || [ -L "$HELPER" ]; then regular_root_file "$HELPER" '0:755:1'; compare_encoded '\(base64(helper))' "$HELPER"; rm -f "$HELPER"; fi
            if [ -e "$DEFAULT" ] || [ -L "$DEFAULT" ]; then regular_root_file "$DEFAULT" '0:644:1'; rm -f "$DEFAULT"; fi
            if [ -e "$SERVICE" ] || [ -L "$SERVICE" ]; then regular_root_file "$SERVICE" '0:644:1'; compare_encoded '\(base64(service))' "$SERVICE"; rm -f "$SERVICE"; fi
            for item in legacy-helper legacy-service legacy-meta; do path="$STATE/$item"; [ ! -e "$path" ] && [ ! -L "$path" ] || { regular_root_file "$path" '0:600:1'; rm -f "$path"; }; done
            retire_state_atomically
            /usr/bin/systemctl daemon-reload
            trap - EXIT HUP INT TERM
            """
        }
    }

    static func managedApplyScript(
        source: PWMFanManualConfiguration,
        dutyPercent: Int,
        persist: Bool,
        resume: Bool = false
    ) -> String {
        precondition((0...100).contains(dutyPercent))
        let old = PWMFanConfiguration.manual(source)
        let updated = PWMFanConfiguration.manual(
            try! PWMFanManualConfiguration(
                pin: source.pin,
                dutyPercent: dutyPercent
            )
        )
        let applyTransition = PWMFanTransitionState(
            source: old,
            target: .configuration(updated),
            phase: .prepared,
            requirement: .reboot,
            kind: .configurationChange
        )
        let applyingJournal = journal(
            source: old,
            target: .configuration(updated),
            kind: .configurationChange,
            requirement: .reboot,
            phase: "applying",
            bootIDExpression: "BOOT_ID"
        )
        let guardScript: String
        if resume {
            guardScript = stateGuard(
                defaultConfiguration: old,
                allowJournal: true,
                alternateDefaultConfiguration: updated
            ) + "\n" + journalGuard(
                transition: applyTransition,
                sameBoot: nil,
                recoveryPhase: "applying"
            )
        } else {
            guardScript = stateGuard(
                defaultConfiguration: old,
                allowJournal: false
            )
        }
        let beginPersistent = persist && !resume
            ? "write_journal '\(base64(applyingJournal))'"
            : "true"
        let finishPersistent = persist ? """
        write_fixed '\(base64(defaultFile(for: updated)))' "$DEFAULT" 0644
        rm -f "$STATE/journal"; sync -f "$STATE"
        """ : "true"
        return mutationCommon + "\n" + manualRuntimeFunction + "\n"
            + guardScript + "\n" + exactBlockGuard(block: block(for: old))
            + "\n" + transitionPreflight(for: old)
            + "\nverify_no_gpiofan_live\nverify_no_pigpio\n" + """
        \(beginPersistent)
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        apply_manual_runtime \(source.pin.rawValue) \(dutyPercent)
        verify_manual_live \(source.pin.rawValue) \(dutyPercent)
        \(finishPersistent)
        trap - EXIT HUP INT TERM
        """
    }

    static let completeStateCleanupScript = mutationCommon + "\n" + """
    cleanup_reserved_temps
    cleanup_partial_stage
    [ ! -e "$STATE_STAGE" ] && [ ! -L "$STATE_STAGE" ]
    recover_retired_state
    [ ! -e "$STATE_REMOVAL" ] && [ ! -L "$STATE_REMOVAL" ]
    """

    /// Full stock gpio-fan proof used by the external pigpio restore path.
    /// The returned shell is read-only and validates the exact policy, active-
    /// high DT node, bound platform device, cooling map, trip, and thermal
    /// cooling-device association.
    static func externalAutomaticLiveGuard(
        configuration: PWMFanAutomaticConfiguration
    ) -> String {
        mutationCommon + "\nverify_automatic_live "
            + "\(configuration.pin.rawValue) "
            + "\(configuration.turnOnCelsius) "
            + "\(configuration.hysteresisCelsius)"
    }

    private static let manualRuntimeFunction = #"""
apply_manual_runtime() {
  requested_pin="$1"; requested_duty="$2"
  case "$requested_pin" in 12|18) channel=0;;13|19) channel=1;;*)exit 75;;esac
  case "$requested_duty" in ''|*[!0-9]*) exit 75;;esac; [ "$requested_duty" -le 100 ] || exit 75
  chip=''; count=0
  for candidate in /sys/class/pwm/pwmchip*; do
    [ -d "$candidate" ] && [ -r "$candidate/npwm" ] && [ -r "$candidate/device/of_node/compatible" ] || continue
    compatible="$(tr '\000' '\n' < "$candidate/device/of_node/compatible" 2>/dev/null || :)"
    printf '%s\n' "$compatible" | grep -Eq '^(brcm,bcm2835-pwm|brcm,bcm2711-pwm|brcm,bcm2712-pwm|raspberrypi,rp1-pwm)$' || continue
    npwm="$(cat "$candidate/npwm")"; case "$npwm" in ''|*[!0-9]*)exit 75;;esac; [ "$npwm" -gt "$channel" ] || continue
    chip="$candidate"; count=$((count + 1))
  done
  [ "$count" = 1 ] && [ -d "$chip/pwm$channel" ]
  pwm="$chip/pwm$channel"; old_period="$(cat "$pwm/period")"; old_duty="$(cat "$pwm/duty_cycle")"; old_enabled="$(cat "$pwm/enable")"
  case "$old_period:$old_duty:$old_enabled" in *[!0-9:]*|*::* )exit 75;;esac
  if ! (set -e; [ "$old_enabled" = 0 ] || printf '%s\n' 0 > "$pwm/enable"; printf '%s\n' 0 > "$pwm/duty_cycle"; printf '%s\n' 40000 > "$pwm/period"; printf '%s\n' $((40000 * requested_duty / 100)) > "$pwm/duty_cycle"; printf '%s\n' 1 > "$pwm/enable"); then
    printf '%s\n' 0 > "$pwm/enable" 2>/dev/null || :; printf '%s\n' 0 > "$pwm/duty_cycle" 2>/dev/null || :; printf '%s\n' "$old_period" > "$pwm/period" 2>/dev/null || :; printf '%s\n' "$old_duty" > "$pwm/duty_cycle" 2>/dev/null || :
    printf '%s\n' "$old_enabled" > "$pwm/enable" 2>/dev/null || { printf '%s\n' 0 > "$pwm/enable" 2>/dev/null || :; printf '%s\n' 0 > "$pwm/duty_cycle" 2>/dev/null || :; printf '%s\n' 40000 > "$pwm/period" 2>/dev/null || :; printf '%s\n' 40000 > "$pwm/duty_cycle" 2>/dev/null || :; printf '%s\n' 1 > "$pwm/enable" 2>/dev/null || :; }
    return 75
  fi
}
"""#

    private static let mutationCommon: String = {
        #"""
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077
STATE=/var/lib/casanative-pwm-fan
STATE_STAGE=/var/lib/.casanative-pwm-fan.new
STATE_REMOVAL=/var/lib/.casanative-pwm-fan.removing
LOCK="$STATE/lock"
HELPER=/usr/local/sbin/casanative-pwm-fan
DEFAULT=/etc/default/casanative-pwm-fan
SERVICE=/etc/systemd/system/casanative-pwm-fan.service
CFG=''
CFG_TMP=''

regular_root_file() {
  [ -f "$1" ] && [ ! -L "$1" ] &&
    [ "$(stat -c %g "$1" 2>/dev/null || :)" = 0 ] &&
    [ "$(stat -c '%u:%a:%h' "$1" 2>/dev/null || :)" = "$2" ]
}
trusted_parent() {
  path="$1"
  [ -d "$path" ] && [ ! -L "$path" ] && [ "$(stat -c '%u:%g' "$path" 2>/dev/null || :)" = 0:0 ] || return 1
  mode="$(stat -c %a "$path" 2>/dev/null || :)"; case "$mode" in ???|????) :;; *) return 1;; esac
  group="$(printf '%s' "$mode" | cut -c$((${#mode}-1)))"; other="$(printf '%s' "$mode" | cut -c${#mode})"; case "$group$other" in *[2367]*) return 1;; esac
}
validate_fixed_parents() {
  for parent in /usr /usr/local /usr/local/bin /usr/local/sbin /etc /etc/default /etc/systemd /etc/systemd/system /var /var/lib; do trusted_parent "$parent" || exit 75; done
}
effective_unit_exact() {
  unit="$1"; expected="$2"
  fragment="$(/usr/bin/systemctl show -p FragmentPath --value "$unit" 2>/dev/null || :)"
  load="$(/usr/bin/systemctl show -p LoadState --value "$unit" 2>/dev/null || :)"
  dropins="$(/usr/bin/systemctl show -p DropInPaths --value "$unit" 2>/dev/null || :)"
  [ "$fragment" = "$expected" ] && [ "$load" = loaded ] && [ -z "$dropins" ]
}
validate_fixed_parents
canonical_journal_shape() {
  regular_root_file "$1" '0:600:1' || return 1
  awk -F= '
    BEGIN{key[1]="VERSION";key[2]="PHASE";key[3]="KIND";key[4]="REQUIREMENT";key[5]="PREPARED_BOOT_ID";key[6]="SOURCE_MODE";key[7]="SOURCE_PIN";key[8]="SOURCE_DUTY";key[9]="SOURCE_TEMP";key[10]="SOURCE_HYST";key[11]="TARGET_MODE";key[12]="TARGET_PIN";key[13]="TARGET_DUTY";key[14]="TARGET_TEMP";key[15]="TARGET_HYST";key[16]="SOURCE_SERVICE_ENABLED";key[17]="TARGET_SERVICE_ENABLED";ok=1}
    {if(NR>17 || $1!=key[NR] || index(substr($0,length($1)+2),"=") || $0 ~ /[[:cntrl:]]/)ok=0}
    END{exit !(ok && NR==17)}
  ' "$1" || return 1
  [ "$(sed -n '1p' "$1")" = VERSION=2 ] || return 1
  phase="$(sed -n '2s/^PHASE=//p' "$1")"; case "$phase" in prepared|cancelling|finalizing|legacyConverting|legacyRestoring|legacyDiscarding|applying) :;; *) return 1;; esac
  kind="$(sed -n '3s/^KIND=//p' "$1")"; case "$kind" in change|rollback|uninstall) :;; *) return 1;; esac
  requirement="$(sed -n '4s/^REQUIREMENT=//p' "$1")"; case "$requirement" in reboot|shutdown) :;; *) return 1;; esac
  prepared="$(sed -n '5s/^PREPARED_BOOT_ID=//p' "$1")"; printf '%s\n' "$prepared" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || return 1
  source_mode="$(sed -n '6s/^SOURCE_MODE=//p' "$1")"; source_pin="$(sed -n '7s/^SOURCE_PIN=//p' "$1")"; source_duty="$(sed -n '8s/^SOURCE_DUTY=//p' "$1")"; source_temp="$(sed -n '9s/^SOURCE_TEMP=//p' "$1")"; source_hyst="$(sed -n '10s/^SOURCE_HYST=//p' "$1")"
  target_mode="$(sed -n '11s/^TARGET_MODE=//p' "$1")"; target_pin="$(sed -n '12s/^TARGET_PIN=//p' "$1")"; target_duty="$(sed -n '13s/^TARGET_DUTY=//p' "$1")"; target_temp="$(sed -n '14s/^TARGET_TEMP=//p' "$1")"; target_hyst="$(sed -n '15s/^TARGET_HYST=//p' "$1")"
  case "$phase" in
    legacyConverting) [ "$kind:$requirement:$source_mode:$target_mode:$target_pin:$target_duty" = change:reboot:none:manual:18:50 ] || return 1;;
    legacyRestoring|legacyDiscarding) [ "$kind:$requirement:$source_mode:$source_pin:$source_duty:$target_mode:$target_pin:$target_duty" = change:reboot:manual:18:50:manual:18:50 ] || return 1;;
    applying) [ "$kind:$requirement:$source_mode:$target_mode:$source_pin" = "change:reboot:manual:manual:$target_pin" ] || return 1;;
    *)
      if [ "$source_mode" != none ] && [ "$target_mode" != uninstalled ]; then
        if [ "$source_mode" != "$target_mode" ]; then [ "$source_pin" = "$target_pin" ] || return 1
        elif [ "$source_mode" = manual ]; then [ "$source_pin" != "$target_pin" ] && [ "$source_duty" = "$target_duty" ] || return 1
        elif [ "$source_pin" = "$target_pin" ]; then { [ "$source_temp" != "$target_temp" ] || [ "$source_hyst" != "$target_hyst" ]; } || return 1
        else [ "$source_temp" = "$target_temp" ] && [ "$source_hyst" = "$target_hyst" ] || return 1; fi
      fi;;
  esac
  return 0
}
compare_encoded() {
  /usr/bin/printf '%s' "$1" | /usr/bin/base64 -d | cmp -s - "$2"
}
read_boot_id() {
  value="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || :)"
  printf '%s\n' "$value" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || exit 75
  printf '%s\n' "$value"
}
resolve_config() {
  validate_fixed_parents
  if [ -e /boot/firmware/config.txt ] || [ -L /boot/firmware/config.txt ]; then
    [ -f /boot/firmware/config.txt ] && [ ! -L /boot/firmware/config.txt ] || exit 75; CFG=/boot/firmware/config.txt
  elif [ -e /boot/config.txt ] || [ -L /boot/config.txt ]; then
    [ -f /boot/config.txt ] && [ ! -L /boot/config.txt ] || exit 75; CFG=/boot/config.txt
  else exit 75; fi
  [ "$(stat -c '%u:%g:%h:%F' "$CFG" 2>/dev/null || :)" = '0:0:1:regular file' ] || exit 75
  mode="$(stat -c %a "$CFG" 2>/dev/null || :)"
  case "$mode" in ???|????) :;; *) exit 75;; esac
  group="$(printf '%s' "$mode" | cut -c$((${#mode}-1)))"; other="$(printf '%s' "$mode" | cut -c${#mode})"
  case "$group$other" in *[2367]*) exit 75;; esac
  parent="${CFG%/*}"
  [ -d "$parent" ] && [ ! -L "$parent" ] && [ "$(stat -c '%u:%g' "$parent" 2>/dev/null || :)" = 0:0 ] || exit 75
  parent_mode="$(stat -c %a "$parent" 2>/dev/null || :)"; pg="$(printf '%s' "$parent_mode" | cut -c$((${#parent_mode}-1)))"; po="$(printf '%s' "$parent_mode" | cut -c${#parent_mode})"; case "$pg$po" in *[2367]*) exit 75;; esac
  grep -Eiq '^[[:space:]]*include[[:space:]]+' "$CFG" && exit 75
  CFG_TMP="${CFG%/*}/.casanative-pwm-fan.tmp"
  [ ! -e "$CFG_TMP" ] && [ ! -L "$CFG_TMP" ] || exit 75
}
resolve_config_for_recovery() {
  validate_fixed_parents
  if [ -e /boot/firmware/config.txt ] || [ -L /boot/firmware/config.txt ]; then
    [ -f /boot/firmware/config.txt ] && [ ! -L /boot/firmware/config.txt ] || exit 75; CFG=/boot/firmware/config.txt
  elif [ -e /boot/config.txt ] || [ -L /boot/config.txt ]; then
    [ -f /boot/config.txt ] && [ ! -L /boot/config.txt ] || exit 75; CFG=/boot/config.txt
  else exit 75; fi
  [ "$(stat -c '%u:%g:%h:%F' "$CFG" 2>/dev/null || :)" = '0:0:1:regular file' ] || exit 75
  mode="$(stat -c %a "$CFG" 2>/dev/null || :)"; case "$mode" in ???|????) :;; *) exit 75;; esac
  group="$(printf '%s' "$mode" | cut -c$((${#mode}-1)))"; other="$(printf '%s' "$mode" | cut -c${#mode})"; case "$group$other" in *[2367]*) exit 75;; esac
  parent="${CFG%/*}"; [ -d "$parent" ] && [ ! -L "$parent" ] && [ "$(stat -c '%u:%g' "$parent" 2>/dev/null || :)" = 0:0 ] || exit 75
  parent_mode="$(stat -c %a "$parent" 2>/dev/null || :)"; pg="$(printf '%s' "$parent_mode" | cut -c$((${#parent_mode}-1)))"; po="$(printf '%s' "$parent_mode" | cut -c${#parent_mode})"; case "$pg$po" in *[2367]*) exit 75;; esac
  grep -Eiq '^[[:space:]]*include[[:space:]]+' "$CFG" && exit 75
  CFG_TMP="${CFG%/*}/.casanative-pwm-fan.tmp"
}
strip_owned_blocks() {
  awk '
    function clean(v){sub(/\r$/, "", v); return v}
    BEGIN{bad=0}
    {
      line=clean($0)
      if(line=="# BEGIN CasaNative PWM Fan" || line=="# BEGIN CasaNative GPIO Fan"){
        a=""; b=""; if((getline a)<=0 || (getline b)<=0){bad=1;next}; a=clean(a); b=clean(b)
        if(line=="# BEGIN CasaNative PWM Fan"){
          if(a !~ /^dtoverlay=pwm,pin=(12|13|18|19),func=(2|4)$/ || b!="# END CasaNative PWM Fan")bad=1
        }else if(a !~ /^dtoverlay=gpio-fan,gpiopin=(12|13|18|19),temp=([4-7][0-9]000),hyst=([5-9]000|1[0-5]000)$/ || b!="# END CasaNative GPIO Fan")bad=1
        next
      }
      print line
    }
    END{if(bad)exit 75}
  ' "$1"
}
recover_config_temp() {
  resolve_config_for_recovery
  [ -e "$CFG_TMP" ] || [ -L "$CFG_TMP" ] || return 0
  regular_root_file "$CFG_TMP" "0:$(stat -c %a "$CFG" 2>/dev/null || :):1" || regular_root_file "$CFG_TMP" '0:600:1'
  if [ -e "$STATE/journal" ] && canonical_journal_shape "$STATE/journal"; then
    rm -f "$CFG_TMP"; sync -f "${CFG%/*}"; return 0
  fi
  current_base="$(strip_owned_blocks "$CFG" | /usr/bin/base64 -w0)"
  staged_base="$(strip_owned_blocks "$CFG_TMP" | /usr/bin/base64 -w0)"
  if [ "$current_base" != "$staged_base" ]; then
    # Fresh install appends only an unconditional [all] scope around the
    # owned block. Removing blank/[all] tail lines must recover exact input.
    staged_base="$(strip_owned_blocks "$CFG_TMP" | awk '{lines[NR]=$0} END{n=NR;while(n>0&&(lines[n]==""||lines[n]=="[all]"))n--;for(i=1;i<=n;i++)print lines[i]}' | /usr/bin/base64 -w0)"
    [ "$current_base" = "$staged_base" ] || exit 75
  fi
  rm -f "$CFG_TMP"; sync -f "${CFG%/*}"
}
recover_fixed_temp() {
  destination="$1"; permissions="$2"; expected="$3"; alternate="${4:-}"
  temporary="$destination.tmp"; [ -e "$temporary" ] || [ -L "$temporary" ] || return 0
  regular_root_file "$temporary" "0:${permissions#0}:1" || regular_root_file "$temporary" '0:600:1'
  if ! compare_encoded "$expected" "$temporary" && { [ -z "$alternate" ] || ! compare_encoded "$alternate" "$temporary"; }; then
    if [ -e "$destination" ] || [ -L "$destination" ]; then
      regular_root_file "$destination" "0:${permissions#0}:1"
      { compare_encoded "$expected" "$destination" || { [ -n "$alternate" ] && compare_encoded "$alternate" "$destination"; }; } || exit 75
      rm -f "$temporary"; sync -f "${destination%/*}"; return 0
    fi
    if canonical_journal_shape "$STATE/journal"; then
      rm -f "$temporary"; sync -f "${destination%/*}"; return 0
    fi
    exit 75
  fi
  chown 0:0 "$temporary"; chmod "$permissions" "$temporary"; sync -f "$temporary"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    regular_root_file "$destination" "0:${permissions#0}:1"
    { cmp -s "$temporary" "$destination" || compare_encoded "$expected" "$destination" || { [ -n "$alternate" ] && compare_encoded "$alternate" "$destination"; }; } || exit 75
    rm -f "$temporary"
  else
    mv "$temporary" "$destination"
  fi
  sync -f "${destination%/*}"
}
recover_legacy_meta_temp() {
  temporary="$STATE/legacy-meta.tmp"; [ -e "$temporary" ] || [ -L "$temporary" ] || return 0
  regular_root_file "$temporary" '0:600:1'
  if ! grep -Eq '^SERVICE_ENABLED=(0|1)$' "$temporary" || [ "$(wc -l < "$temporary" | tr -d ' ')" != 1 ]; then
    if [ -e "$STATE/legacy-meta" ] || [ -L "$STATE/legacy-meta" ]; then
      regular_root_file "$STATE/legacy-meta" '0:600:1'; grep -Eq '^SERVICE_ENABLED=(0|1)$' "$STATE/legacy-meta"; [ "$(wc -l < "$STATE/legacy-meta" | tr -d ' ')" = 1 ]
      rm -f "$temporary"; sync -f "$STATE"; return 0
    fi
    canonical_journal_shape "$STATE/journal"; rm -f "$temporary"; sync -f "$STATE"; return 0
  fi
  if [ -e "$STATE/legacy-meta" ] || [ -L "$STATE/legacy-meta" ]; then
    regular_root_file "$STATE/legacy-meta" '0:600:1'; cmp -s "$temporary" "$STATE/legacy-meta"; rm -f "$temporary"
  else
    mv "$temporary" "$STATE/legacy-meta"
  fi
  sync -f "$STATE"
}
adopt_journal_temp() {
  [ -e "$STATE/journal.tmp" ] || [ -L "$STATE/journal.tmp" ] || return 0
  regular_root_file "$STATE/journal.tmp" '0:600:1'
  if ! canonical_journal_shape "$STATE/journal.tmp"; then
    if [ -e "$STATE/journal" ] || [ -L "$STATE/journal" ]; then canonical_journal_shape "$STATE/journal" || exit 75; fi
    rm -f "$STATE/journal.tmp"; sync -f "$STATE"; return 0
  fi
  if [ -e "$STATE/journal" ] || [ -L "$STATE/journal" ]; then
    regular_root_file "$STATE/journal" '0:600:1'; [ "$(wc -l < "$STATE/journal" | tr -d ' ')" = 17 ]
    [ "$(sed '2s/^PHASE=.*/PHASE=PHASE/' "$STATE/journal" | /usr/bin/base64 -w0)" = "$(sed '2s/^PHASE=.*/PHASE=PHASE/' "$STATE/journal.tmp" | /usr/bin/base64 -w0)" ]
  fi
  mv -f "$STATE/journal.tmp" "$STATE/journal"; sync -f "$STATE"
}
write_fixed() {
  encoded="$1"; destination="$2"; permissions="$3"; temporary="$destination.tmp"
  [ ! -e "$temporary" ] && [ ! -L "$temporary" ] || exit 75
  (umask 077; set -C; : > "$temporary")
  regular_root_file "$temporary" '0:600:1'
  /usr/bin/printf '%s' "$encoded" | /usr/bin/base64 -d > "$temporary"
  chown 0:0 "$temporary"; chmod "$permissions" "$temporary"
  sync -f "$temporary"; mv -f "$temporary" "$destination"
  sync -f "$destination"; sync -f "${destination%/*}"
}
write_journal() {
  encoded="$1"; temporary="$STATE/journal.tmp"; [ ! -e "$temporary" ] && [ ! -L "$temporary" ] || exit 75
  (umask 077; set -C; : > "$temporary")
  regular_root_file "$temporary" '0:600:1'
  boot_id="$(read_boot_id)"
  /usr/bin/printf '%s' "$encoded" | /usr/bin/base64 -d |
    sed "s/^PREPARED_BOOT_ID=BOOT_ID$/PREPARED_BOOT_ID=$boot_id/" > "$temporary"
  [ "$(wc -l < "$temporary" | tr -d ' ')" = 17 ] || exit 75
  chown 0:0 "$temporary"; chmod 0600 "$temporary"
  sync -f "$temporary"; mv -f "$temporary" "$STATE/journal"
  sync -f "$STATE/journal"; sync -f "$STATE"
}
create_state_with_journal() {
  encoded="$1"; stage=/var/lib/.casanative-pwm-fan.new
  [ -d /var/lib ] && [ ! -L /var/lib ] && [ "$(stat -c '%u:%g' /var/lib 2>/dev/null || :)" = 0:0 ] || exit 75
  [ ! -e "$STATE" ] && [ ! -L "$STATE" ]
  if [ -e "$stage" ] || [ -L "$stage" ]; then
    [ -d "$stage" ] && [ ! -L "$stage" ] && [ "$(stat -c '%u:%g:%a' "$stage" 2>/dev/null || :)" = '0:0:700' ]
    regular_root_file "$stage/lock" '0:600:1'
    exec 7<>"$stage/lock"; flock -x -w 3 7
    for item in "$stage"/*; do [ -e "$item" ] || [ -L "$item" ] || continue; case "${item##*/}" in lock|journal) regular_root_file "$item" '0:600:1';; *) exit 75;; esac; done
    if canonical_journal_shape "$stage/journal"; then
      normalized="$(sed '5s/^PREPARED_BOOT_ID=.*/PREPARED_BOOT_ID=BOOT_ID/' "$stage/journal" | /usr/bin/base64 -w0)"
      [ "$normalized" = "$encoded" ]
    else
      # Reserved root-owned staging only; no published STATE exists. Partial
      # bytes from an interrupted first write are safe to discard/recreate.
      [ ! -e "$STATE" ] && [ ! -L "$STATE" ]
      [ ! -e "$stage/journal" ] && [ ! -L "$stage/journal" ] || regular_root_file "$stage/journal" '0:600:1'
      rm -f "$stage/journal"
      boot_id="$(read_boot_id)"
      (umask 077; set -C; : > "$stage/journal"); regular_root_file "$stage/journal" '0:600:1'
      /usr/bin/printf '%s' "$encoded" | /usr/bin/base64 -d | sed "s/^PREPARED_BOOT_ID=BOOT_ID$/PREPARED_BOOT_ID=$boot_id/" > "$stage/journal"
      canonical_journal_shape "$stage/journal"
      chown 0:0 "$stage/journal"; chmod 0600 "$stage/journal"
      sync -f "$stage/lock"; sync -f "$stage/journal"; sync -f "$stage"
    fi
  else
    mkdir -m 0700 "$stage"; chown 0:0 "$stage"
    (umask 077; set -C; : > "$stage/lock"); regular_root_file "$stage/lock" '0:600:1'
    exec 7<>"$stage/lock"; flock -x -w 3 7
    boot_id="$(read_boot_id)"
    (umask 077; set -C; : > "$stage/journal"); regular_root_file "$stage/journal" '0:600:1'
    /usr/bin/printf '%s' "$encoded" | /usr/bin/base64 -d | sed "s/^PREPARED_BOOT_ID=BOOT_ID$/PREPARED_BOOT_ID=$boot_id/" > "$stage/journal"
    [ "$(wc -l < "$stage/journal" | tr -d ' ')" = 17 ]
    chown 0:0 "$stage/journal"; chmod 0600 "$stage/journal"
    sync -f "$stage/lock"; sync -f "$stage/journal"; sync -f "$stage"
  fi
  mv -T "$stage" "$STATE"; sync -f /var/lib
  flock -u 7; exec 7>&-
}
adopt_staged_state() {
  [ -e "$STATE_STAGE" ] || [ -L "$STATE_STAGE" ] || return 0
  [ ! -e "$STATE" ] && [ ! -L "$STATE" ]
  [ -d "$STATE_STAGE" ] && [ ! -L "$STATE_STAGE" ] && [ "$(stat -c '%u:%g:%a' "$STATE_STAGE" 2>/dev/null || :)" = '0:0:700' ]
  regular_root_file "$STATE_STAGE/lock" '0:600:1'; exec 7<>"$STATE_STAGE/lock"; flock -x -w 3 7
  canonical_journal_shape "$STATE_STAGE/journal"
  for item in "$STATE_STAGE"/*; do [ -e "$item" ] || [ -L "$item" ] || continue; case "${item##*/}" in lock|journal) :;; *) exit 75;; esac; done
  mv -T "$STATE_STAGE" "$STATE"; sync -f /var/lib
  flock -u 7; exec 7>&-
}
retire_state_atomically() {
  [ -d "$STATE" ] && [ ! -L "$STATE" ] && [ "$(stat -c '%u:%g:%a' "$STATE" 2>/dev/null || :)" = '0:0:700' ]
  regular_root_file "$LOCK" '0:600:1'; canonical_journal_shape "$STATE/journal"
  [ ! -e "$STATE_REMOVAL" ] && [ ! -L "$STATE_REMOVAL" ]
  mv -T "$STATE" "$STATE_REMOVAL"; sync -f /var/lib
  # The open flock descriptor keeps the retired generation serialized while
  # its exact two fixed files are removed. A crash leaves a self-describing
  # tombstone that detection fails closed and a retry can finish.
  for item in "$STATE_REMOVAL"/*; do [ -e "$item" ] || [ -L "$item" ] || continue; case "${item##*/}" in lock|journal) :;; *) exit 75;; esac; done
  rm -f "$STATE_REMOVAL/journal" "$STATE_REMOVAL/lock"
  rmdir "$STATE_REMOVAL"; sync -f /var/lib
}
recover_retired_state() {
  [ -e "$STATE_REMOVAL" ] || [ -L "$STATE_REMOVAL" ] || return 0
  [ ! -e "$STATE" ] && [ ! -L "$STATE" ]
  [ -d "$STATE_REMOVAL" ] && [ ! -L "$STATE_REMOVAL" ] && [ "$(stat -c '%u:%g:%a' "$STATE_REMOVAL" 2>/dev/null || :)" = '0:0:700' ]
  for item in "$STATE_REMOVAL"/*; do [ -e "$item" ] || [ -L "$item" ] || continue; case "${item##*/}" in lock|journal) :;; *) exit 75;; esac; done
  if [ -e "$STATE_REMOVAL/lock" ] || [ -L "$STATE_REMOVAL/lock" ]; then regular_root_file "$STATE_REMOVAL/lock" '0:600:1'; exec 7<>"$STATE_REMOVAL/lock"; flock -x -w 3 7; fi
  if [ -e "$STATE_REMOVAL/journal" ] || [ -L "$STATE_REMOVAL/journal" ]; then canonical_journal_shape "$STATE_REMOVAL/journal"; fi
  rm -f "$STATE_REMOVAL/journal" "$STATE_REMOVAL/lock"
  rmdir "$STATE_REMOVAL"; sync -f /var/lib
}
cleanup_partial_stage() {
  [ -e "$STATE_STAGE" ] || [ -L "$STATE_STAGE" ] || return 0
  [ ! -e "$STATE" ] && [ ! -L "$STATE" ]
  [ -d "$STATE_STAGE" ] && [ ! -L "$STATE_STAGE" ] && [ "$(stat -c '%u:%g:%a' "$STATE_STAGE" 2>/dev/null || :)" = '0:0:700' ]
  if [ -e "$STATE_STAGE/lock" ] || [ -L "$STATE_STAGE/lock" ]; then regular_root_file "$STATE_STAGE/lock" '0:600:1'; exec 7<>"$STATE_STAGE/lock"; flock -x -w 3 7; fi
  canonical_journal_shape "$STATE_STAGE/journal" && exit 75 || :
  for item in "$STATE_STAGE"/*; do
    [ -e "$item" ] || [ -L "$item" ] || continue
    case "${item##*/}" in lock|journal) regular_root_file "$item" '0:600:1'; rm -f "$item";; *) exit 75;; esac
  done
  rmdir "$STATE_STAGE"; sync -f /var/lib
}
cleanup_reserved_temps() {
  if [ -e "$STATE" ] || [ -L "$STATE" ]; then
    [ -d "$STATE" ] && [ ! -L "$STATE" ] && [ "$(stat -c '%u:%g:%a' "$STATE" 2>/dev/null || :)" = '0:0:700' ]
    regular_root_file "$LOCK" '0:600:1'; exec 9<>"$LOCK"; flock -x -w 3 9
    for item in "$STATE/journal.tmp" "$STATE/legacy-meta.tmp" "$STATE/legacy-helper.tmp" "$STATE/legacy-service.tmp"; do
      [ -e "$item" ] || [ -L "$item" ] || continue
      regular_root_file "$item" '0:600:1'; rm -f "$item"
    done
    sync -f "$STATE"
  fi
  resolve_config_for_recovery
  for item in "$CFG_TMP" "$HELPER.tmp" "$DEFAULT.tmp" "$SERVICE.tmp"; do
    [ -e "$item" ] || [ -L "$item" ] || continue
    [ -f "$item" ] && [ ! -L "$item" ] && [ "$(stat -c '%u:%g:%h' "$item" 2>/dev/null || :)" = '0:0:1' ] || exit 75
    mode="$(stat -c %a "$item" 2>/dev/null || :)"; case "$mode" in 600|644|755) :;; *) exit 75;; esac
    rm -f "$item"; sync -f "${item%/*}"
  done
}
resume_or_create_state_with_journal() {
  encoded="$1"
  if [ -d "$STATE" ] && [ ! -L "$STATE" ]; then
    [ "$(stat -c '%u:%g:%a' "$STATE" 2>/dev/null || :)" = '0:0:700' ]
    regular_root_file "$LOCK" '0:600:1'; exec 9<>"$LOCK"; flock -x -w 3 9
    adopt_journal_temp
    regular_root_file "$STATE/journal" '0:600:1'
    normalized="$(sed '5s/^PREPARED_BOOT_ID=.*/PREPARED_BOOT_ID=BOOT_ID/' "$STATE/journal" | /usr/bin/base64 -w0)"
    [ "$normalized" = "$encoded" ]
  else
    [ ! -e "$STATE" ] && [ ! -L "$STATE" ]
    create_state_with_journal "$encoded"
    exec 9<>"$LOCK"; flock -x -w 3 9
  fi
}
rewrite_journal_phase() {
  new_phase="$1"; temporary="$STATE/journal.tmp"
  regular_root_file "$STATE/journal" '0:600:1'
  [ "$(wc -l < "$STATE/journal" | tr -d ' ')" = 17 ]
  [ ! -e "$temporary" ] && [ ! -L "$temporary" ]
  sed "2s/^PHASE=.*$/PHASE=$new_phase/" "$STATE/journal" > "$temporary"
  [ "$(sed -n '2p' "$temporary")" = "PHASE=$new_phase" ]
  chown 0:0 "$temporary"; chmod 0600 "$temporary"; sync -f "$temporary"
  mv -f "$temporary" "$STATE/journal"; sync -f "$STATE/journal"; sync -f "$STATE"
}
copy_backup() {
  source="$1"; destination="$2"; temporary="$destination.tmp"
  [ ! -e "$destination" ] && [ ! -L "$destination" ] && [ ! -e "$temporary" ] && [ ! -L "$temporary" ] || exit 75
  (umask 077; set -C; : > "$temporary"); regular_root_file "$temporary" '0:600:1'
  cp "$source" "$temporary"; chown 0:0 "$temporary"; chmod 0600 "$temporary"
  [ "$(stat -c %h "$temporary")" = 1 ] || exit 75
  sync -f "$temporary"; mv "$temporary" "$destination"; sync -f "$STATE"
}
copy_from_backup() {
  source="$1"; destination="$2"; permissions="$3"; temporary="$destination.tmp"
  [ ! -e "$destination" ] && [ ! -L "$destination" ] && [ ! -e "$temporary" ] && [ ! -L "$temporary" ] || exit 75
  cp "$source" "$temporary"; chown 0:0 "$temporary"; chmod "$permissions" "$temporary"
  sync -f "$temporary"; mv "$temporary" "$destination"; sync -f "${destination%/*}"
}
ensure_backup_copy() {
  source="$1"; destination="$2"; permissions="$3"
  regular_root_file "$source" '0:600:1'
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    normalized="${permissions#0}"
    regular_root_file "$destination" "0:$normalized:1"
    cmp -s "$source" "$destination"
  else
    copy_from_backup "$source" "$destination" "$permissions"
  fi
}
find_exact_block() {
  marker="$1"; encoded="$2"
  starts="$(awk -v marker="$marker" '{line=$0; sub(/\r$/, "", line); if(line==marker)print NR}' "$CFG")"
  [ -n "$starts" ] && [ "$(printf '%s\n' "$starts" | wc -l | tr -d ' ')" = 1 ] || return 1
  start="$starts"; end=$((start + 2))
  actual="$(sed -n "${start},${end}p" "$CFG" | sed 's/\r$//' | /usr/bin/base64 -w0)"
  [ "$actual" = "$encoded" ] || return 1
  printf '%s\n' "$start"
}
line_ending() {
  cr="$(awk 'sub(/\r$/, ""){c++} END{print c+0}' "$CFG")"
  plain="$(awk '!/\r$/{c++} END{print c+0}' "$CFG")"
  [ "$cr" = 0 ] || [ "$plain" = 0 ] || exit 75
  [ "$cr" = 0 ] && printf '%s\n' lf || printf '%s\n' crlf
}
append_decoded() {
  encoded="$1"; ending="$2"
  if [ "$ending" = crlf ]; then
    /usr/bin/printf '%s' "$encoded" | /usr/bin/base64 -d | sed 's/$/\r/' >> "$CFG_TMP"
  else
    /usr/bin/printf '%s' "$encoded" | /usr/bin/base64 -d >> "$CFG_TMP"
  fi
}
publish_append() {
  encoded="$1"; ending="$(line_ending)"
  (umask 077; set -C; : > "$CFG_TMP")
  cp -p "$CFG" "$CFG_TMP"
  last="$(tail -c 1 "$CFG" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  if [ -s "$CFG" ] && [ "$last" != 0a ]; then [ "$ending" = crlf ] && printf '\r\n' >> "$CFG_TMP" || printf '\n' >> "$CFG_TMP"; fi
  [ "$ending" = crlf ] && printf '[all]\r\n' >> "$CFG_TMP" || printf '[all]\n' >> "$CFG_TMP"
  append_decoded "$encoded" "$ending"
  [ "$ending" = crlf ] && printf '\r\n' >> "$CFG_TMP" || printf '\n' >> "$CFG_TMP"
  chown --reference="$CFG" "$CFG_TMP"; chmod --reference="$CFG" "$CFG_TMP"
  sync -f "$CFG_TMP"; mv "$CFG_TMP" "$CFG"
}
publish_replace() {
  start="$1"; encoded="$2"; ending="$(line_ending)"; end=$((start + 2))
  (umask 077; set -C; : > "$CFG_TMP")
  [ "$start" -le 1 ] || head -n $((start - 1)) "$CFG" >> "$CFG_TMP"
  if [ -n "$encoded" ]; then append_decoded "$encoded" "$ending"; [ "$ending" = crlf ] && printf '\r\n' >> "$CFG_TMP" || printf '\n' >> "$CFG_TMP"; fi
  tail -n +$((end + 1)) "$CFG" >> "$CFG_TMP"
  chown --reference="$CFG" "$CFG_TMP"; chmod --reference="$CFG" "$CFG_TMP"
  sync -f "$CFG_TMP"; mv "$CFG_TMP" "$CFG"
}
verify_no_pigpio() {
    [ ! -e /usr/bin/pigs ] && [ ! -L /usr/bin/pigs ] && [ ! -e /usr/local/bin/pigs ] && [ ! -L /usr/local/bin/pigs ]
}
verify_manual_live() {
  expected_pin="$1"; expected_duty="$2"
  case "$expected_pin" in 12|18) channel=0;;13|19) channel=1;;*)exit 75;;esac
  found=0
  for pwm in /sys/class/pwm/pwmchip*/pwm*; do
    [ -d "$pwm" ] || continue
    case "${pwm##*/}" in pwm0) actual_channel=0;;pwm1) actual_channel=1;;*)exit 75;;esac
    [ "$actual_channel" = "$channel" ] || exit 75
    period="$(cat "$pwm/period" 2>/dev/null || :)"; duty="$(cat "$pwm/duty_cycle" 2>/dev/null || :)"; enabled="$(cat "$pwm/enable" 2>/dev/null || :)"
    case "$period:$duty:$enabled" in *[!0-9:]*|*::* ) exit 75;; esac
    [ "$period" = 40000 ] && [ "$enabled" = 1 ] && [ $((duty * 100 / period)) = "$expected_duty" ] || exit 75
    compatible="$(tr '\000' '\n' < "${pwm%/*}/device/of_node/compatible" 2>/dev/null || :)"
    printf '%s\n' "$compatible" | grep -Eq '^(brcm,bcm2835-pwm|brcm,bcm2711-pwm|brcm,bcm2712-pwm|raspberrypi,rp1-pwm)$' || exit 75
    found=$((found + 1))
  done
  [ "$found" = 1 ]
  resolved=0
  for pins_file in $(find /sys/firmware/devicetree/base -type f -path '*pwm*' -name brcm,pins 2>/dev/null); do
    node="${pins_file%/*}"; [ -r "$node/brcm,function" ] || continue
    phex="$(od -An -tx1 -N4 "$pins_file" | tr -d ' \n')"; fhex="$(od -An -tx1 -N4 "$node/brcm,function" | tr -d ' \n')"
    case "$phex:$fhex" in 0000000c:00000004)p=12;;0000000d:00000004)p=13;;00000012:00000002)p=18;;00000013:00000002)p=19;;*)continue;;esac
    [ "$p" = "$expected_pin" ] && resolved=$((resolved + 1))
  done
  [ "$resolved" = 1 ]
}
verify_no_gpiofan_live() {
  for compatible in /sys/firmware/devicetree/base/*/compatible /sys/firmware/devicetree/base/*/*/compatible; do
    [ -r "$compatible" ] || continue
    tr '\000' '\n' < "$compatible" 2>/dev/null | grep -qx gpio-fan && exit 75 || :
  done
}
verify_automatic_live() {
  expected_pin="$1"; expected_temp="$2"; expected_hyst="$3"; found=0
  for node in /sys/firmware/devicetree/base/* /sys/firmware/devicetree/base/*/*; do
    [ -r "$node/compatible" ] || continue
    tr '\000' '\n' < "$node/compatible" | grep -qx gpio-fan || continue
    [ "$(tr '\000' '\n' < "$node/status" 2>/dev/null || printf okay)" = okay ] || exit 75
    phex="$(od -An -tx1 -N12 "$node/gpios" | tr -d ' \n')"; phandle="$(od -An -tx1 -N4 "$node/phandle" | tr -d ' \n')"
    [ "${#phex}" = 24 ] && [ "${#phandle}" = 8 ] && [ "$(printf '%s' "$phex" | cut -c17-24)" = 00000000 ] || exit 75
    [ "$(od -An -tx1 -N16 "$node/gpio-fan,speed-map" | tr -d ' \n')" = 00000000000000000000138800000001 ] && [ "$(od -An -tx1 -N4 "$node/#cooling-cells" | tr -d ' \n')" = 00000002 ] || exit 75
    cell="$(printf '%s' "$phex" | cut -c9-16)"; case "$cell" in 0000000c)p=12;;0000000d)p=13;;00000012)p=18;;00000013)p=19;;*)exit 75;;esac
    bound=0; bound_device=''
    for device in /sys/bus/platform/drivers/gpio-fan/*; do
      [ -L "$device/driver" ] && { [ -e "$device/of_node" ] || [ -L "$device/of_node" ]; } || continue
      [ "$(readlink -f "$device/of_node")" = "$(readlink -f "$node")" ] || continue
      bound=$((bound + 1)); bound_device="$device"
    done
    [ "$bound" = 1 ] || exit 75
    map_count=0; trip=''; dt_zone=''
    for map in /sys/firmware/devicetree/base/thermal-zones/*/cooling-maps/*; do
      [ -r "$map/cooling-device" ] && [ -r "$map/trip" ] || continue
      cooling="$(od -An -tx1 "$map/cooling-device" | tr -d ' \n')"; [ "${#cooling}" = 24 ] || continue
      [ "$(printf '%s' "$cooling" | cut -c1-8)" = "$phandle" ] || continue
      [ "$(printf '%s' "$cooling" | cut -c9-24)" = 0000000100000001 ] || exit 75
      trip="$(od -An -tx1 -N4 "$map/trip" | tr -d ' \n')"; dt_zone="${map%%/cooling-maps/*}"; map_count=$((map_count + 1))
    done
    [ "$map_count" = 1 ] || exit 75
    trip_count=0; trip_node=''
    for candidate in /sys/firmware/devicetree/base/thermal-zones/*/trips/*; do [ -r "$candidate/phandle" ] || continue; [ "$(od -An -tx1 -N4 "$candidate/phandle" | tr -d ' \n')" = "$trip" ] && { trip_count=$((trip_count + 1)); trip_node="$candidate"; }; done
    [ "$trip_count" = 1 ] && [ "$(tr '\000' '\n' < "$trip_node/type")" = active ] || exit 75
    thex="$(od -An -tx1 -N4 "$trip_node/temperature" | tr -d ' \n')"; hhex="$(od -An -tx1 -N4 "$trip_node/hysteresis" | tr -d ' \n')"
    [ "${#thex}" = 8 ] && [ "${#hhex}" = 8 ] || exit 75
    [ "$p" = "$expected_pin" ] && [ $((0x$thex)) = $((expected_temp * 1000)) ] && [ $((0x$hhex)) = $((expected_hyst * 1000)) ] || exit 75
    matching_cooling=0
    for cooling in /sys/class/thermal/cooling_device*; do
      [ -r "$cooling/type" ] && [ -r "$cooling/max_state" ] && [ -r "$cooling/cur_state" ] || continue
      [ "$(cat "$cooling/type")" = gpio-fan ] && [ "$(cat "$cooling/max_state")" = 1 ] || continue
      case "$(cat "$cooling/cur_state")" in 0|1) :;; *) exit 75;; esac
      bindings=0
      for zone in /sys/class/thermal/thermal_zone*; do
        [ -r "$zone/type" ] || continue
        case "$(cat "$zone/type")" in cpu-thermal|cpu_thermal) :;; *) continue;; esac
        for link in "$zone"/cdev*; do
          [ -L "$link" ] || continue
          name="${link##*/}"; case "$name" in cdev[0-9]*) :;; *) continue;; esac
          [ "$(readlink -f "$link")" = "$(readlink -f "$cooling")" ] || continue
          index="${name#cdev}"; [ -r "$zone/cdev${index}_trip_point" ] || exit 75
          trip_index="$(cat "$zone/cdev${index}_trip_point")"; case "$trip_index" in ''|*[!0-9]*)exit 75;;esac
          [ -r "$zone/trip_point_${trip_index}_type" ] && [ -r "$zone/trip_point_${trip_index}_temp" ] && [ -r "$zone/trip_point_${trip_index}_hyst" ] || exit 75
          [ "$(cat "$zone/trip_point_${trip_index}_type")" = active ] || continue
          [ "$(cat "$zone/trip_point_${trip_index}_temp")" = $((expected_temp * 1000)) ] || continue
          [ "$(cat "$zone/trip_point_${trip_index}_hyst")" = $((expected_hyst * 1000)) ] || continue
          bindings=$((bindings + 1))
        done
      done
      [ "$bindings" = 1 ] || continue
      matching_cooling=$((matching_cooling + 1))
    done
    [ "$matching_cooling" = 1 ] || exit 75
    found=$((found + 1))
  done
  [ "$found" = 1 ]
}
verify_live_absent() {
  for pwm in /sys/class/pwm/pwmchip*/pwm*; do [ ! -d "$pwm" ] || exit 75; done
  for compatible in /sys/firmware/devicetree/base/*/compatible /sys/firmware/devicetree/base/*/*/compatible; do
    [ -r "$compatible" ] || continue; tr '\000' '\n' < "$compatible" | grep -qx gpio-fan && exit 75 || :
  done
  verify_no_pigpio
}
verify_legacy_backups() {
  regular_root_file "$STATE/legacy-helper" '0:600:1'
  regular_root_file "$STATE/legacy-service" '0:600:1'
  regular_root_file "$STATE/legacy-meta" '0:600:1'
  compare_encoded '#LEGACY_HELPER#' "$STATE/legacy-helper"
  compare_encoded '#LEGACY_SERVICE#' "$STATE/legacy-service"
  grep -Eq '^SERVICE_ENABLED=(0|1)$' "$STATE/legacy-meta"
  [ "$(wc -l < "$STATE/legacy-meta" | tr -d ' ')" = 1 ]
}
"""#
            .replacingOccurrences(
                of: "#LEGACY_HELPER#",
                with: base64(legacyHelper)
            )
            .replacingOccurrences(
                of: "#LEGACY_SERVICE#",
                with: base64(legacyService)
            )
    }()

    private static func provisionPreflight(
        for configuration: PWMFanConfiguration
    ) -> String {
        let common = """
        ! grep -Eq '^[[:space:]]*# BEGIN (CasaNative PWM Fan|CasaNative GPIO Fan|fan50)[[:space:]]*$' "$CFG"
        ! grep -Eiq '^[[:space:]]*dtoverlay=(pwm|pwm1|pwm-2chan|pwm-gpio|pwm-gpio-fan|pwm-ir-tx|gpio-fan|audremap)(,|[[:space:]]|$)' "$CFG"
        ! grep -Eiq '^[[:space:]]*(dtparam=(audio|i2s)=on|dtoverlay=.*(hifiberry|i2s))' "$CFG"
        verify_live_absent
        """
        switch configuration {
        case .manual:
            return common + """
            controllers=0
            for chip in /sys/class/pwm/pwmchip*; do
              [ -r "$chip/npwm" ] && [ -r "$chip/device/of_node/compatible" ] || continue
              compatible="$(tr '\\000' '\\n' < "$chip/device/of_node/compatible" 2>/dev/null || :)"
              printf '%s\\n' "$compatible" | grep -Eq '^(brcm,bcm2835-pwm|brcm,bcm2711-pwm|brcm,bcm2712-pwm|raspberrypi,rp1-pwm)$' || continue
              controllers=$((controllers + 1))
            done
            [ "$controllers" = 1 ]
            """
        case .automatic:
            return common + """
            overlays=0
            for item in /boot/firmware/overlays/gpio-fan.dtbo /boot/overlays/gpio-fan.dtbo; do [ -r "$item" ] && overlays=$((overlays + 1)); done
            [ "$overlays" = 1 ]
            release="$(uname -r)"
            [ -d /sys/module/gpio_fan ] || grep -Eq '(^|/)gpio-fan\\.ko' "/lib/modules/$release/modules.builtin" 2>/dev/null || find "/lib/modules/$release" -type f -name 'gpio-fan.ko*' -print -quit 2>/dev/null | grep -q .
            zones=0
            for zone in /sys/class/thermal/thermal_zone*; do
              [ -r "$zone/type" ] && [ -r "$zone/temp" ] || continue
              case "$(cat "$zone/type")" in cpu-thermal|cpu_thermal) zones=$((zones + 1));; esac
            done
            [ "$zones" = 1 ]
            """
        }
    }

    private static func stateGuard(
        defaultConfiguration: PWMFanConfiguration?,
        allowJournal: Bool,
        allowLegacyBackup: Bool = false,
        alternateDefaultConfiguration: PWMFanConfiguration? = nil
    ) -> String {
        let expectedDefault = defaultConfiguration.map(defaultFile(for:))
        let alternateDefault = alternateDefaultConfiguration.map(
            defaultFile(for:)
        )
        return """
        [ -d "$STATE" ] && [ ! -L "$STATE" ]
        [ "$(stat -c '%u:%g:%a' "$STATE" 2>/dev/null || :)" = '0:0:700' ]
        regular_root_file "$LOCK" '0:600:1'
        exec 9<>"$LOCK"
        flock -x -w 3 9
        \(allowJournal ? "adopt_journal_temp\nrecover_config_temp\nrecover_fixed_temp \"$HELPER\" 0755 '\(base64(helper))'\nrecover_fixed_temp \"$SERVICE\" 0644 '\(base64(service))'" : "[ ! -e \"$STATE/journal.tmp\" ] && [ ! -L \"$STATE/journal.tmp\" ]")
        \(allowJournal && expectedDefault != nil ? "recover_fixed_temp \"$DEFAULT\" 0644 '\(base64(expectedDefault!))' '\(alternateDefault.map { base64($0) } ?? "")'" : "true")
        resolve_config
        regular_root_file "$HELPER" '0:755:1'
        regular_root_file "$SERVICE" '0:644:1'
        compare_encoded '\(base64(helper))' "$HELPER"
        compare_encoded '\(base64(service))' "$SERVICE"
        \(expectedDefault.map { expected in
            if let alternateDefault {
                return "regular_root_file \"$DEFAULT\" '0:644:1'\n{ compare_encoded '\(base64(expected))' \"$DEFAULT\" || compare_encoded '\(base64(alternateDefault))' \"$DEFAULT\"; }"
            }
            return "regular_root_file \"$DEFAULT\" '0:644:1'\ncompare_encoded '\(base64(expected))' \"$DEFAULT\""
        } ?? "[ ! -e \"$DEFAULT\" ] && [ ! -L \"$DEFAULT\" ]")
        \(
            allowJournal
                ? "regular_root_file \"$STATE/journal\" '0:600:1'"
                : "[ ! -e \"$STATE/journal\" ] && [ ! -L \"$STATE/journal\" ]"
        )
        backup_count=0
        for item in legacy-helper legacy-service legacy-meta; do { [ -e "$STATE/$item" ] || [ -L "$STATE/$item" ]; } && backup_count=$((backup_count + 1)); done
        \(
            allowLegacyBackup
                ? "[ \"$backup_count\" = 0 ] || { [ \"$backup_count\" = 3 ] && verify_legacy_backups; }"
                : "[ \"$backup_count\" = 0 ]"
        )
        for item in "$STATE"/*; do
          [ -e "$item" ] || [ -L "$item" ] || continue
          case "${item##*/}" in
            lock\(allowJournal ? "|journal" : "")\(allowLegacyBackup ? "|legacy-helper|legacy-service|legacy-meta" : "")) :;;
            *) exit 75;;
          esac
        done
        """
    }

    private static func journalGuard(
        transition: PWMFanTransitionState,
        sameBoot: Bool?,
        recoveryPhase: String? = nil,
        allowPreparedServiceEither: Bool = false
    ) -> String {
        let expected = journal(
            source: transition.source,
            target: transition.target,
            kind: transition.kind,
            requirement: transition.requirement,
            bootIDExpression: "BOOT_ID"
        )
        let targetServiceEnabled = transition.source?.mode == .manual
            || transition.target.configuration?.mode == .manual
        return """
        regular_root_file "$STATE/journal" '0:600:1'
        [ "$(wc -l < "$STATE/journal" | tr -d ' ')" = 17 ]
        actual_phase="$(sed -n '2s/^PHASE=//p' "$STATE/journal")"
        case "$actual_phase" in prepared\(recoveryPhase.map { "|\($0)" } ?? "")) :;; *) exit 75;; esac
        normalized="$(sed -e '2s/^PHASE=.*/PHASE=prepared/' -e '5s/^PREPARED_BOOT_ID=.*/PREPARED_BOOT_ID=BOOT_ID/' "$STATE/journal" | /usr/bin/base64 -w0)"
        [ "$normalized" = '\(base64(expected))' ]
        prepared="$(sed -n '5s/^PREPARED_BOOT_ID=//p' "$STATE/journal")"
        printf '%s\n' "$prepared" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        current_boot="$(read_boot_id)"
        \(sameBoot.map { $0 ? "[ \"$current_boot\" = \"$prepared\" ]" : "[ \"$current_boot\" != \"$prepared\" ]" } ?? "true")
        service_state="$(/usr/bin/systemctl is-enabled casanative-pwm-fan.service 2>/dev/null || :)"
        case "$actual_phase:$service_state" in
          prepared:\(targetServiceEnabled ? "enabled" : "disabled")\(allowPreparedServiceEither ? "|prepared:enabled|prepared:disabled" : "")\(recoveryPhase.map { "|\($0):enabled|\($0):disabled|\($0):not-found" } ?? "")) :;;
          *) exit 75;;
        esac
        """
    }

    private static func partialCleanupStateGuard(
        expectedDefault: PWMFanConfiguration?,
        allowLegacyBackup: Bool = false
    ) -> String {
        let expected = expectedDefault.map(defaultFile(for:))
        return """
        adopt_staged_state
        [ -d "$STATE" ] && [ ! -L "$STATE" ] && [ "$(stat -c '%u:%g:%a' "$STATE")" = '0:0:700' ]
        regular_root_file "$LOCK" '0:600:1'; exec 9<>"$LOCK"; flock -x -w 3 9
        adopt_journal_temp
        recover_config_temp
        recover_fixed_temp "$HELPER" 0755 '\(base64(helper))'
        recover_fixed_temp "$SERVICE" 0644 '\(base64(service))'
        \(expected.map { "recover_fixed_temp \"$DEFAULT\" 0644 '\(base64($0))'" } ?? "true")
        resolve_config
        regular_root_file "$STATE/journal" '0:600:1'
        if [ -e "$HELPER" ] || [ -L "$HELPER" ]; then regular_root_file "$HELPER" '0:755:1'; compare_encoded '\(base64(helper))' "$HELPER"; fi
        if [ -e "$SERVICE" ] || [ -L "$SERVICE" ]; then regular_root_file "$SERVICE" '0:644:1'; compare_encoded '\(base64(service))' "$SERVICE"; fi
        if [ -e "$DEFAULT" ] || [ -L "$DEFAULT" ]; then
          regular_root_file "$DEFAULT" '0:644:1'
          \(expected.map { "compare_encoded '\(base64($0))' \"$DEFAULT\"" } ?? "exit 75")
        fi
        for item in legacy-helper legacy-service legacy-meta; do
          path="$STATE/$item"; [ -e "$path" ] || [ -L "$path" ] || continue
          \(allowLegacyBackup ? "case \"$item\" in legacy-helper) regular_root_file \"$path\" '0:600:1'; compare_encoded '\(base64(legacyHelper))' \"$path\";; legacy-service) regular_root_file \"$path\" '0:600:1'; compare_encoded '\(base64(legacyService))' \"$path\";; legacy-meta) regular_root_file \"$path\" '0:600:1'; grep -Eq '^SERVICE_ENABLED=(0|1)$' \"$path\"; [ \"$(wc -l < \"$path\" | tr -d ' ')\" = 1 ];; esac" : "exit 75")
        done
        for item in "$STATE"/*; do [ -e "$item" ] || [ -L "$item" ] || continue; case "${item##*/}" in lock|journal\(allowLegacyBackup ? "|legacy-helper|legacy-service|legacy-meta" : "")) :;; *) exit 75;; esac; done
        """
    }

    private static func exactBlockGuard(block: String) -> String {
        let marker = block.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return """
        block_start="$(find_exact_block '\(marker)' '\(base64(block + "\n"))')"
        [ -n "$block_start" ]
        """
    }

    private static let absentOwnedBlockGuard = """
    ! grep -Eq '^[[:space:]]*# BEGIN CasaNative (PWM|GPIO) Fan[[:space:]]*$' "$CFG"
    """

    private static func liveGuard(
        for configuration: PWMFanConfiguration?
    ) -> String {
        guard let configuration else { return "verify_live_absent" }
        switch configuration {
        case let .manual(value):
            return "verify_manual_live \(value.pin.rawValue) \(value.dutyPercent)\nverify_no_pigpio"
        case let .automatic(value):
            return "verify_automatic_live \(value.pin.rawValue) \(value.turnOnCelsius) \(value.hysteresisCelsius)\nverify_no_pigpio"
        }
    }

    private static func configReplacement(
        from source: String?,
        to target: String?
    ) -> String {
        guard let source else {
            guard let target else { return "exit 75" }
            return absentOwnedBlockGuard + "\npublish_append '\(base64(target))'"
        }
        return exactBlockGuard(block: source) + "\n" +
            "publish_replace \"$block_start\" '\(target.map { base64($0) } ?? "")'"
    }

    private static func eitherGenerationGuard(
        source: String?,
        target: String?
    ) -> String {
        let sourceMarker = source?.split(separator: "\n").first.map(String.init)
        let targetMarker = target?.split(separator: "\n").first.map(String.init)
        let sourceProbe = source.map {
            "find_exact_block '\(sourceMarker!)' '\(base64($0 + "\n"))' >/dev/null 2>&1"
        } ?? absentOwnedBlockGuard
        let targetProbe = target.map {
            "find_exact_block '\(targetMarker!)' '\(base64($0 + "\n"))' >/dev/null 2>&1"
        } ?? absentOwnedBlockGuard
        return "{ \(sourceProbe); } || { \(targetProbe); }"
    }

    private static func idempotentReplacement(
        from source: String?,
        to target: String?
    ) -> String {
        let targetGuard = target.map(exactBlockGuard(block:))
            ?? absentOwnedBlockGuard
        guard let source else {
            guard let target else { return absentOwnedBlockGuard }
            let marker = target.split(separator: "\n").first.map(String.init) ?? ""
            return """
            if find_exact_block '\(marker)' '\(base64(target + "\n"))' >/dev/null 2>&1; then
              :
            else
              \(absentOwnedBlockGuard)
              publish_append '\(base64(target))'
            fi
            """
        }
        let marker = source.split(separator: "\n").first.map(String.init) ?? ""
        return """
        if block_start="$(find_exact_block '\(marker)' '\(base64(source + "\n"))')"; then
          publish_replace "$block_start" '\(target.map { base64($0) } ?? "")'
        else
          \(targetGuard)
        fi
        """
    }

    private static func transitionScript(
        source: PWMFanConfiguration,
        target: PWMFanTransitionTarget,
        requirement: PWMFanTransitionRequirement,
        kind: PWMFanTransitionKind
    ) -> String {
        let targetConfiguration = target.configuration
        let sourceBlock = block(for: source)
        let targetBlock = targetConfiguration.map(block(for:))
        let allowExistingJournal = kind == .rollback
        let allowBackup = source.pin == targetConfiguration?.pin
        let journalValue = journal(
            source: source,
            target: target,
            kind: kind,
            requirement: requirement,
            bootIDExpression: "BOOT_ID"
        )
        let targetPreflight = targetConfiguration.map(transitionPreflight(for:)) ?? "true"
        if kind == .rollback {
            return rollbackTransitionScript(
                liveTarget: source,
                originalSource: targetConfiguration,
                requirement: requirement
            )
        }
        return mutationCommon + "\n" + stateGuard(
            defaultConfiguration: source,
            allowJournal: allowExistingJournal,
            allowLegacyBackup: allowBackup
        ) + "\n" + exactBlockGuard(block: sourceBlock) + "\n" + liveGuard(for: source) + "\n" + targetPreflight + "\n" + """
        effective_unit_exact casanative-pwm-fan.service /etc/systemd/system/casanative-pwm-fan.service
        saved_journal=''
        rollback_prepare() {
          result="$?"
          rm -f "$CFG_TMP" "$STATE/journal.tmp"
          exit "$result"
        }
        trap rollback_prepare EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        write_journal '\(base64(journalValue))'
        # Keep the Manual helper enabled whenever either generation needs it.
        \(source.mode == .manual || targetConfiguration?.mode == .manual ? "/usr/bin/systemctl enable casanative-pwm-fan.service >/dev/null" : "/usr/bin/systemctl disable casanative-pwm-fan.service >/dev/null")
        \(configReplacement(from: sourceBlock, to: targetBlock))
        sync -f "$CFG"; sync -f "${CFG%/*}"
        sync -f "$STATE"
        trap - EXIT HUP INT TERM
        """
    }

    private static func rollbackTransitionScript(
        liveTarget: PWMFanConfiguration,
        originalSource: PWMFanConfiguration?,
        requirement: PWMFanTransitionRequirement
    ) -> String {
        guard let originalSource else { return "exit 75" }
        let oldTransition = PWMFanTransitionState(
            source: originalSource,
            target: .configuration(liveTarget),
            phase: .bootedAwaitingConfirmation,
            requirement: requirement,
            kind: .configurationChange
        )
        return rollbackTransitionScript(originalTransition: oldTransition)
    }

    private static func rollbackTransitionScript(
        originalTransition: PWMFanTransitionState
    ) -> String {
        guard originalTransition.phase == .bootedAwaitingConfirmation,
              originalTransition.kind != .rollback,
              originalTransition.source != nil
                || originalTransition.target.configuration != nil else {
            return "exit 75"
        }
        let liveSource = originalTransition.target.configuration
        let restored = originalTransition.source
        let reverseTarget = restored.map { PWMFanTransitionTarget.configuration($0) }
            ?? .uninstalled
        let requirement: PWMFanTransitionRequirement
        if liveSource == nil || restored == nil {
            requirement = .fullShutdown
        } else {
            requirement = liveSource?.pin == restored?.pin
                ? .reboot
                : .fullShutdown
        }
        let retainedDefault = restored ?? liveSource
        guard let retainedDefault else { return "exit 75" }
        let reverse = journal(
            source: liveSource,
            target: reverseTarget,
            kind: .rollback,
            requirement: requirement,
            bootIDExpression: "BOOT_ID"
        )
        return mutationCommon + "\n" + stateGuard(
            defaultConfiguration: retainedDefault,
            allowJournal: true,
            allowLegacyBackup: liveSource?.pin == restored?.pin
        ) + "\n" + journalGuard(
            transition: originalTransition,
            sameBoot: false
        ) + "\n" + (
            liveSource.map { exactBlockGuard(block: block(for: $0)) }
                ?? absentOwnedBlockGuard
        ) + "\n" + liveGuard(for: liveSource) + "\n"
            + (restored.map(transitionPreflight(for:)) ?? "true") + "\n" + """
        effective_unit_exact casanative-pwm-fan.service /etc/systemd/system/casanative-pwm-fan.service
        write_journal '\(base64(reverse))'
        \(restored?.mode == .manual || liveSource?.mode == .manual ? "/usr/bin/systemctl enable casanative-pwm-fan.service >/dev/null" : "/usr/bin/systemctl disable casanative-pwm-fan.service >/dev/null")
        \(configReplacement(from: liveSource.map(block(for:)), to: restored.map(block(for:))))
        sync -f "$CFG"; sync -f "${CFG%/*}"; sync -f "$STATE"
        """
    }

    static func completeRollbackPreparationScript(
        transition: PWMFanTransitionState
    ) -> String {
        guard transition.kind == .rollback,
              transition.phase == .prepared,
              transition.source != nil
                || transition.target.configuration != nil else {
            return "exit 75"
        }
        let source = transition.source
        let target = transition.target.configuration
        let retainedDefault = target ?? source
        guard let retainedDefault else { return "exit 75" }
        let sourceBlock = source.map(block(for:))
        let targetBlock = target.map(block(for:))
        return mutationCommon + "\n" + stateGuard(
            defaultConfiguration: retainedDefault,
            allowJournal: true,
            allowLegacyBackup: source?.pin == target?.pin
        ) + "\n" + journalGuard(
            transition: transition,
            sameBoot: nil,
            allowPreparedServiceEither: true
        ) + "\n" + eitherGenerationGuard(
            source: sourceBlock,
            target: targetBlock
        ) + "\n" + liveGuard(for: source) + "\n"
            + (target.map(transitionPreflight(for:)) ?? "true") + "\n" + """
        effective_unit_exact casanative-pwm-fan.service /etc/systemd/system/casanative-pwm-fan.service
        \(source?.mode == .manual || target?.mode == .manual ? "/usr/bin/systemctl enable casanative-pwm-fan.service >/dev/null" : "/usr/bin/systemctl disable casanative-pwm-fan.service >/dev/null")
        \(idempotentReplacement(from: sourceBlock, to: targetBlock))
        sync -f "$CFG"; sync -f "${CFG%/*}"; sync -f "$STATE"
        """
    }

    private static func transitionPreflight(
        for configuration: PWMFanConfiguration
    ) -> String {
        let resources = """
        awk '
          BEGIN{skip=0;bad=0}
          {line=$0;sub(/\r$/, "", line)}
          line=="# BEGIN CasaNative PWM Fan" || line=="# BEGIN CasaNative GPIO Fan" {skip=3}
          skip>0 {skip--; next}
          line !~ /^[[:space:]]*#/ && line ~ /^[[:space:]]*(dtoverlay=(pwm|pwm1|pwm-2chan|pwm-gpio|pwm-gpio-fan|pwm-ir-tx|gpio-fan|audremap)|dtparam=(audio|i2s)=on|dtoverlay=.*(hifiberry|i2s))/ {bad=1}
          END{exit bad}
        ' "$CFG"
        """
        switch configuration {
        case .manual:
            return resources
        case .automatic:
            return resources + "\n" + """
            overlays=0
            for item in /boot/firmware/overlays/gpio-fan.dtbo /boot/overlays/gpio-fan.dtbo; do [ -r "$item" ] && overlays=$((overlays + 1)); done
            [ "$overlays" = 1 ]
            release="$(uname -r)"
            [ -d /sys/module/gpio_fan ] || grep -Eq '(^|/)gpio-fan\\.ko' "/lib/modules/$release/modules.builtin" 2>/dev/null || find "/lib/modules/$release" -type f -name 'gpio-fan.ko*' -print -quit 2>/dev/null | grep -q .
            zones=0
            for zone in /sys/class/thermal/thermal_zone*; do [ -r "$zone/type" ] || continue; case "$(cat "$zone/type")" in cpu-thermal|cpu_thermal) zones=$((zones + 1));; esac; done
            [ "$zones" = 1 ]
            """
        }
    }

    private static let removeFreshInstallShell = """
    verify_live_absent
    for item in "$STATE"/*; do [ -e "$item" ] || [ -L "$item" ] || continue; case "${item##*/}" in lock|journal) :;; *) exit 75;; esac; done
    if [ -e "$HELPER" ] || [ -L "$HELPER" ]; then regular_root_file "$HELPER" '0:755:1'; compare_encoded '#HELPER#' "$HELPER"; rm -f "$HELPER"; fi
    if [ -e "$DEFAULT" ] || [ -L "$DEFAULT" ]; then regular_root_file "$DEFAULT" '0:644:1'; rm -f "$DEFAULT"; fi
    if [ -e "$SERVICE" ] || [ -L "$SERVICE" ]; then regular_root_file "$SERVICE" '0:644:1'; compare_encoded '#SERVICE#' "$SERVICE"; rm -f "$SERVICE"; fi
    /usr/bin/systemctl daemon-reload
    """
        .replacingOccurrences(of: "#HELPER#", with: base64(helper))
        .replacingOccurrences(of: "#SERVICE#", with: base64(service))

    private static let removeFinalizedInstallShell = """
    verify_live_absent
    for item in "$STATE"/*; do [ -e "$item" ] || [ -L "$item" ] || continue; case "${item##*/}" in lock|journal|legacy-helper|legacy-service|legacy-meta) :;; *) exit 75;; esac; done
    [ ! -e "$STATE/legacy-helper" ] && [ ! -L "$STATE/legacy-helper" ] && [ ! -e "$STATE/legacy-service" ] && [ ! -L "$STATE/legacy-service" ] && [ ! -e "$STATE/legacy-meta" ] && [ ! -L "$STATE/legacy-meta" ]
    if [ -e "$HELPER" ] || [ -L "$HELPER" ]; then regular_root_file "$HELPER" '0:755:1'; compare_encoded '#HELPER#' "$HELPER"; rm -f "$HELPER"; fi
    if [ -e "$DEFAULT" ] || [ -L "$DEFAULT" ]; then regular_root_file "$DEFAULT" '0:644:1'; rm -f "$DEFAULT"; fi
    if [ -e "$SERVICE" ] || [ -L "$SERVICE" ]; then regular_root_file "$SERVICE" '0:644:1'; compare_encoded '#SERVICE#' "$SERVICE"; rm -f "$SERVICE"; fi
    /usr/bin/systemctl daemon-reload
    """
        .replacingOccurrences(of: "#HELPER#", with: base64(helper))
        .replacingOccurrences(of: "#SERVICE#", with: base64(service))

    private static func base64(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }
}

extension PWMFanScripts {
    static func privilegedReadOnlyDetection(
        password: String
    ) -> SSHCommandRequest {
        privileged(
            script: PWMFanManagedLifecycleScripts.detectionShell,
            password: password
        )
    }

    static func provision(
        configuration: PWMFanConfiguration,
        requirement: PWMFanTransitionRequirement
    ) -> String {
        PWMFanManagedLifecycleScripts.provisionScript(
            configuration: configuration,
            requirement: requirement
        )
    }

    static func prepareConfigurationChange(
        source: PWMFanConfiguration,
        target: PWMFanConfiguration,
        requirement: PWMFanTransitionRequirement,
        kind: PWMFanTransitionKind
    ) -> String {
        PWMFanManagedLifecycleScripts.prepareConfigurationChangeScript(
            source: source,
            target: target,
            requirement: requirement,
            kind: kind
        )
    }

    static func prepareRollback(
        transition: PWMFanTransitionState
    ) -> String {
        PWMFanManagedLifecycleScripts.prepareRollbackScript(
            transition: transition
        )
    }

    static func completeRollbackPreparation(
        transition: PWMFanTransitionState
    ) -> String {
        PWMFanManagedLifecycleScripts.completeRollbackPreparationScript(
            transition: transition
        )
    }

    static func cancelPreparedChange(
        transition: PWMFanTransitionState
    ) -> String {
        PWMFanManagedLifecycleScripts.cancelPreparedChangeScript(
            transition: transition
        )
    }

    static func finalizePreparedChange(
        transition: PWMFanTransitionState
    ) -> String {
        PWMFanManagedLifecycleScripts.finalizePreparedChangeScript(
            transition: transition
        )
    }

    static func prepareUninstall(
        source: PWMFanConfiguration
    ) -> String {
        PWMFanManagedLifecycleScripts.prepareUninstallScript(source: source)
    }

    static func convertExactLegacyFan50() -> String {
        PWMFanManagedLifecycleScripts.convertExactLegacyFan50Script()
    }

    static func resolveLegacyBackup(
        _ resolution: PWMFanLegacyBackupResolution
    ) -> String {
        PWMFanManagedLifecycleScripts.resolveLegacyBackupScript(resolution)
    }

    static func managedLifecycleApply(
        source: PWMFanManualConfiguration,
        dutyPercent: Int,
        persist: Bool,
        resume: Bool = false
    ) -> String {
        PWMFanManagedLifecycleScripts.managedApplyScript(
            source: source,
            dutyPercent: dutyPercent,
            persist: persist,
            resume: resume
        )
    }

    static func completeStateCleanup() -> String {
        PWMFanManagedLifecycleScripts.completeStateCleanupScript
    }
}
