#!/usr/bin/env bash
# =============================================================================
# php2shell-ubuntu.sh — CVE-2026-109618 / CVE-2026-109619 (PHP2Shell)
# Diagnóstico, actualización y mitigación temporal de PHP en Ubuntu.
#
# Uso (como root):
#   sudo bash php2shell-ubuntu.sh check            # solo diagnóstico (no cambia nada)
#   sudo bash php2shell-ubuntu.sh upgrade          # actualiza paquetes PHP y reinicia FPM/Apache
#   sudo bash php2shell-ubuntu.sh mitigate         # desactiva session.upload_progress
#   sudo bash php2shell-ubuntu.sh mitigate --memory  # + memory_limit=-1 (pools FPM y mod_php; ojo RAM)
#   sudo bash php2shell-ubuntu.sh undo             # quita las mitigaciones (tras parchear)
#
# Versiones upstream corregidas: 8.2.35, 8.3.36, 8.4.27, 8.5.12.
# Paquetes de Ubuntu (24.04: 8.3.6-0ubuntu0.24.04.13, ESM en 20.04/18.04)
# llevan el parche backporteado: se detecta por el changelog del paquete.
# =============================================================================
set -uo pipefail

MODE="${1:-check}"
OPT="${2:-}"
CVE_RE='CVE-2026-10961[89]'
DROPIN="99-php2shell-mitigation.ini"
MARK_BEGIN="; >>> php2shell mitigation"
MARK_END="; <<< php2shell mitigation"
APACHE_CONF_NAME="php2shell-mitigation"
APACHE_CONF="/etc/apache2/conf-available/$APACHE_CONF_NAME.conf"
APACHE_CONF_EN="/etc/apache2/conf-enabled/$APACHE_CONF_NAME.conf"

declare -A FIXED=( [8.2]=8.2.35 [8.3]=8.3.36 [8.4]=8.4.27 [8.5]=8.5.12 )

red(){ printf '\e[31m%s\e[0m\n' "$*"; }
grn(){ printf '\e[32m%s\e[0m\n' "$*"; }
ylw(){ printf '\e[33m%s\e[0m\n' "$*"; }
hdr(){ printf '\n\e[1m== %s ==\e[0m\n' "$*"; }

[[ $EUID -eq 0 ]] || { red "Ejecuta como root (sudo)."; exit 1; }
# shellcheck disable=SC1091
. /etc/os-release
UBU="${VERSION_ID:-?}"

php_versions(){
  dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'php*-common' 2>/dev/null \
    | awk '$1 ~ /^ii/ {print $2}' \
    | sed -nE 's/^php([0-9]+\.[0-9]+)-common$/\1/p' | sort -V
}

pkg_source(){
  case "$1" in
    *deb.sury.org*) echo "ondrej/sury PPA" ;;
    *esm*)          echo "Ubuntu ESM (Pro)" ;;
    *ubuntu*)       echo "Ubuntu oficial" ;;
    *)              echo "desconocido" ;;
  esac
}

is_patched(){ # $1=versión rama  $2=versión paquete
  local v="$1" pkgver="$2" up f
  for f in /usr/share/doc/php"$v"-*/changelog.Debian.gz; do
    [[ -f "$f" ]] && zgrep -qE "$CVE_RE" "$f" && return 0
  done
  up="${pkgver#*:}"; up="${up%%-*}"; up="${up%%+*}"
  [[ -n "${FIXED[$v]:-}" ]] && dpkg --compare-versions "$up" ge "${FIXED[$v]}" && return 0
  return 1
}

ini_val(){ # $1=versión $2=sapi $3=directiva
  local v="$1" s="$2" d="$3"
  if command -v "php$v" >/dev/null 2>&1; then
    PHP_INI_SCAN_DIR="/etc/php/$v/$s/conf.d" "php$v" -c "/etc/php/$v/$s/php.ini" \
      -r "echo var_export(ini_get('$d'), true);" 2>/dev/null
  else
    echo "(sin php$v-cli)"
  fi
}

restart_services(){
  local v
  for v in $(php_versions); do
    if systemctl is-active --quiet "php$v-fpm"; then
      systemctl restart "php$v-fpm" && grn "  reiniciado php$v-fpm" || red "  fallo al reiniciar php$v-fpm"
    fi
  done
  if compgen -G "/etc/apache2/mods-enabled/php*.load" >/dev/null && systemctl is-active --quiet apache2; then
    systemctl restart apache2 && grn "  reiniciado apache2 (mod_php)" || red "  fallo al reiniciar apache2"
  fi
}

do_check(){
  hdr "Sistema: $(hostname) — Ubuntu $UBU ($PRETTY_NAME)"
  local versions v pkgver cand src s
  versions=$(php_versions)
  [[ -z "$versions" ]] && { ylw "No hay PHP instalado por paquetes."; return; }

  for v in $versions; do
    pkgver=$(dpkg-query -W -f='${Version}' "php$v-common")
    cand=$(apt-cache policy "php$v-common" 2>/dev/null | awk '/Candidate:/{print $2}')
    src=$(pkg_source "$pkgver")
    hdr "PHP $v"
    echo "  Paquete instalado : $pkgver  [$src]"
    [[ -n "$cand" && "$cand" != "$pkgver" ]] && ylw "  Candidato en apt  : $cand  (hay actualización pendiente)"
    if is_patched "$v" "$pkgver"; then
      grn "  Estado            : PARCHEADO"
    else
      red "  Estado            : VULNERABLE"
      case "$v" in
        7.*|8.0|8.1)
          if [[ "$src" == "ondrej/sury PPA" ]]; then
            ylw "  -> Rama sin fix oficial de php.net. Mitigar YA y migrar a 8.3/8.4."
          else
            ylw "  -> Fix solo vía Ubuntu Pro/ESM (USN-8948-2). Revisa: pro status / pro fix CVE-2026-109618"
          fi ;;
        *) ylw "  -> Corre: sudo bash $0 upgrade" ;;
      esac
    fi
    for s in fpm apache2 cgi; do
      [[ -f "/etc/php/$v/$s/php.ini" ]] || continue
      echo "  [$s] session.upload_progress.enabled=$(ini_val "$v" "$s" session.upload_progress.enabled)  memory_limit=$(ini_val "$v" "$s" memory_limit)  post_max_size=$(ini_val "$v" "$s" post_max_size)"
    done
    if compgen -G "/etc/php/$v/fpm/pool.d/*.conf" >/dev/null; then
      grep -HnE 'upload_progress|memory_limit' /etc/php/"$v"/fpm/pool.d/*.conf 2>/dev/null \
        | sed 's/^/  [pool] /'
    fi
    systemctl is-active --quiet "php$v-fpm" && echo "  php$v-fpm: activo"
  done

  hdr "Procesos con binario PHP antiguo en memoria (requieren reinicio)"
  local stale
  stale=$(grep -lE '(php-fpm|libphp)[^ ]* \(deleted\)' /proc/[0-9]*/maps 2>/dev/null | cut -d/ -f3 | sort -un | tr '\n' ' ')
  if [[ -n "$stale" ]]; then red "  PIDs: $stale"; else grn "  Ninguno"; fi

  if [[ -d /etc/apache2 ]]; then
    hdr "Apache: directivas PHP en la config (mod_php)"
    if [[ -e "$APACHE_CONF_EN" ]]; then grn "  Mitigación Apache activa ($APACHE_CONF_EN)"; else echo "  Mitigación Apache: no aplicada"; fi
    grep -rnE 'php_(admin_)?(value|flag).*(memory_limit|upload_progress|post_max_size)' \
      /etc/apache2/conf-enabled/ /etc/apache2/sites-enabled/ 2>/dev/null | sed 's/^/  /'
  fi

  if [[ "$UBU" =~ ^(14|16|18|20)\. ]]; then
    hdr "Ubuntu Pro / ESM (necesario para parchear en $UBU)"
    if ! command -v pro >/dev/null 2>&1; then
      red "  Cliente 'pro' no instalado (apt install ubuntu-advantage-tools)"
    elif pro status 2>/dev/null | grep -qi 'not attached'; then
      red "  Ubuntu Pro NO está adjunto: ESM no entrega parches. Ejecuta: pro attach <token>"
    else
      pro status 2>/dev/null | grep -E '^(esm-infra|esm-apps)' | sed 's/^/  /'
      pro status 2>/dev/null | grep -qE '^esm-infra +yes +enabled' \
        && grn "  esm-infra habilitado" || red "  esm-infra NO habilitado: pro enable esm-infra"
    fi
  fi
}

do_upgrade(){
  hdr "Actualizando paquetes PHP"
  apt-get update || { red "apt-get update falló"; exit 1; }
  mapfile -t PKGS < <(dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' 'php*' 'libapache2-mod-php*' 2>/dev/null \
                      | awk '$1 ~ /^ii/ {print $2}')
  [[ ${#PKGS[@]} -eq 0 ]] && { ylw "No hay paquetes PHP."; return; }
  DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade \
    -o Dpkg::Options::=--force-confold "${PKGS[@]}" || { red "La actualización falló"; exit 1; }
  hdr "Reiniciando servicios"
  restart_services
  do_check
}

do_mitigate(){
  local v s pool
  hdr "Aplicando mitigación temporal"
  for v in $(php_versions); do
    for s in fpm apache2 cgi; do
      [[ -d "/etc/php/$v/$s/conf.d" ]] || continue
      cat > "/etc/php/$v/$s/conf.d/$DROPIN" <<'EOF'
; PHP2Shell (CVE-2026-109618 / CVE-2026-109619) — mitigación temporal.
; Eliminar una vez instalado PHP parcheado: sudo bash php2shell-ubuntu.sh undo
session.upload_progress.enabled = 0
EOF
      grn "  $v/$s: drop-in escrito"
    done
    for pool in /etc/php/"$v"/fpm/pool.d/*.conf; do
      [[ -f "$pool" ]] || continue
      grep -qF "$MARK_BEGIN" "$pool" && { echo "  $pool: ya mitigado"; continue; }
      cp -a "$pool" "$pool.bak-php2shell"
      {
        echo ""
        echo "$MARK_BEGIN"
        echo "php_admin_flag[session.upload_progress.enabled] = off"
        [[ "$OPT" == "--memory" ]] && echo "php_admin_value[memory_limit] = -1"
        echo "$MARK_END"
      } >> "$pool"
      grn "  $pool: mitigado${OPT:+ ($OPT)}"
    done
    if command -v "php-fpm$v" >/dev/null 2>&1; then
      "php-fpm$v" -t >/dev/null 2>&1 || { red "  php-fpm$v -t falló; revisa la config antes de reiniciar"; exit 1; }
    fi
  done
  # mod_php: php_admin_* en la config de Apache (no lo puede pisar .htaccess ni ini_set)
  if compgen -G "/etc/apache2/mods-enabled/php*.load" >/dev/null; then
    local mem_line=""
    [[ "$OPT" == "--memory" ]] && mem_line="    php_admin_value memory_limit -1"
    cat > "$APACHE_CONF" <<EOF
# PHP2Shell (CVE-2026-109618 / CVE-2026-109619) — mitigación temporal (mod_php).
# Quitar tras parchear: sudo bash php2shell-ubuntu.sh undo
<IfModule mod_php7.c>
    php_admin_flag session.upload_progress.enabled off
$mem_line
</IfModule>
<IfModule mod_php.c>
    php_admin_flag session.upload_progress.enabled off
$mem_line
</IfModule>
EOF
    a2enconf -q "$APACHE_CONF_NAME" >/dev/null
    if apache2ctl configtest >/dev/null 2>&1; then
      grn "  Apache mod_php: $APACHE_CONF habilitado${OPT:+ ($OPT)}"
    else
      a2disconf -q "$APACHE_CONF_NAME" >/dev/null; rm -f "$APACHE_CONF"
      red "  apache2ctl configtest falló; mitigación Apache revertida"; exit 1
    fi
    if grep -rqE 'php_(admin_)?value +memory_limit' /etc/apache2/sites-enabled/ 2>/dev/null; then
      ylw "  Ojo: hay memory_limit definido en sites-enabled; en el vhost puede pisar el global."
    fi
  fi
  [[ "$OPT" == "--memory" ]] && ylw "  memory_limit=-1: un solo request puede consumir toda la RAM. Vigila memoria y revierte al parchear."
  hdr "Reiniciando servicios"
  restart_services
}

do_undo(){
  local v s pool
  hdr "Quitando mitigaciones"
  for v in $(php_versions); do
    for s in fpm apache2 cgi; do
      rm -f "/etc/php/$v/$s/conf.d/$DROPIN" && echo "  $v/$s: drop-in eliminado"
    done
    for pool in /etc/php/"$v"/fpm/pool.d/*.conf; do
      [[ -f "$pool" ]] && grep -qF "$MARK_BEGIN" "$pool" || continue
      sed -i "/^; >>> php2shell mitigation/,/^; <<< php2shell mitigation/d" "$pool"
      echo "  $pool: limpiado"
    done
  done
  if [[ -f "$APACHE_CONF" ]]; then
    a2disconf -q "$APACHE_CONF_NAME" >/dev/null 2>&1; rm -f "$APACHE_CONF"
    echo "  Apache: $APACHE_CONF_NAME eliminado"
  fi
  restart_services
}

case "$MODE" in
  check)    do_check ;;
  upgrade)  do_upgrade ;;
  mitigate) do_mitigate ;;
  undo)     do_undo ;;
  *) echo "Uso: $0 {check|upgrade|mitigate [--memory]|undo}"; exit 1 ;;
esac
