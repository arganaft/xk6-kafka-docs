#!/bin/sh
# pinot-launcher.sh — universal launcher for Pinot roles
# All resource settings can be overridden via env vars at runtime.

set -eu

ROLE_CMD="${1:-StartController}"

# --- Resource defaults (override via env at runtime) ---------------------
HEAP_MIN="${PINOT_HEAP_MIN:-2g}"
HEAP_MAX="${PINOT_HEAP_MAX:-2g}"
DIRECT_MEM="${PINOT_DIRECT_MEMORY:-}"
GC_PROFILE="${PINOT_GC_PROFILE:-auto}"
EXTRA_OPTS="${PINOT_EXTRA_JAVA_OPTS:-}"
JMX_PORT="${PINOT_JMX_PORT:-8888}"
DISABLE_JMX="${PINOT_DISABLE_JMX:-false}"
LOG4J_CONFIG="${PINOT_LOG4J_CONFIG:-/opt/pinot/etc/conf/log4j2.xml}"
PINOT_CONFIG="${PINOT_CONFIG:-/etc/pinot/${PINOT_ROLE:-controller}.conf}"

# --- GC profile selection ------------------------------------------------
# If PINOT_GC_OPTS is set, use it as-is (full override).
# Else pick from PINOT_GC_PROFILE.
if [ -n "${PINOT_GC_OPTS:-}" ]; then
  GC_OPTS="${PINOT_GC_OPTS}"
else
  case "${GC_PROFILE}" in
    dev)
      # Минимум флагов, быстрый старт, для разработки/CI
      GC_OPTS="-XX:+UseG1GC"
      ;;
    g1)
      GC_OPTS="-XX:+UseG1GC -XX:MaxGCPauseMillis=100 -XX:+UseStringDeduplication"
      ;;
    g1-low-pause)
      GC_OPTS="-XX:+UseG1GC -XX:MaxGCPauseMillis=50 -XX:G1HeapRegionSize=16m -XX:+UseStringDeduplication"
      ;;
    zgc)
      GC_OPTS="-XX:+UseZGC -XX:+ZGenerational -XX:+AlwaysPreTouch"
      ;;
    zgc-hugepages)
      GC_OPTS="-XX:+UseZGC -XX:+ZGenerational -XX:+AlwaysPreTouch -XX:+UseTransparentHugePages"
      ;;
    parallel)
      GC_OPTS="-XX:+UseParallelGC"
      ;;
    auto|*)
      # Авто: на маленьком heap (<= 4g) — G1, иначе — ZGC generational
      heap_num=$(echo "${HEAP_MAX}" | sed 's/[gG]$//' | sed 's/[mM]$//')
      heap_unit=$(echo "${HEAP_MAX}" | grep -o '[gGmM]$' || echo 'g')
      if [ "${heap_unit}" = "g" ] || [ "${heap_unit}" = "G" ]; then
        if [ "${heap_num}" -le 4 ] 2>/dev/null; then
          GC_OPTS="-XX:+UseG1GC -XX:MaxGCPauseMillis=100"
        else
          GC_OPTS="-XX:+UseZGC -XX:+ZGenerational"
        fi
      else
        GC_OPTS="-XX:+UseG1GC"
      fi
      ;;
  esac
fi

# --- Heap & direct memory ------------------------------------------------
HEAP_OPTS="-Xms${HEAP_MIN} -Xmx${HEAP_MAX}"
if [ -n "${DIRECT_MEM}" ]; then
  HEAP_OPTS="${HEAP_OPTS} -XX:MaxDirectMemorySize=${DIRECT_MEM}"
fi

# --- Container & safety --------------------------------------------------
SAFETY_OPTS="\
  -XX:+UseContainerSupport \
  -XX:+ExitOnOutOfMemoryError \
  -XX:+HeapDumpOnOutOfMemoryError \
  -XX:HeapDumpPath=/var/log/pinot/heapdump.hprof \
  -Djava.security.egd=file:/dev/./urandom \
  -Dlog4j.configurationFile=${LOG4J_CONFIG}"

# AppCDS-архив есть только в нашем образе; защитимся, если он не сгенерился
if [ -f /opt/pinot/lib/pinot.jsa ]; then
  SAFETY_OPTS="${SAFETY_OPTS} -XX:SharedArchiveFile=/opt/pinot/lib/pinot.jsa"
fi

# --- JMX exporter (Prometheus) -------------------------------------------
JMX_OPTS=""
if [ "${DISABLE_JMX}" != "true" ] && [ -f /opt/pinot/lib/jmx_prometheus_javaagent.jar ]; then
  JMX_OPTS="-javaagent:/opt/pinot/lib/jmx_prometheus_javaagent.jar=${JMX_PORT}:/opt/pinot/etc/jmx-exporter-config.yaml"
fi

# --- OpenTelemetry / Jaeger ----------------------------------------------
OTEL_OPTS=""
if [ -n "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" ] && [ -f /opt/pinot/lib/opentelemetry-javaagent.jar ]; then
  OTEL_OPTS="-javaagent:/opt/pinot/lib/opentelemetry-javaagent.jar"
  : "${OTEL_SERVICE_NAME:=pinot-${PINOT_ROLE:-unknown}}"
  export OTEL_SERVICE_NAME
  export OTEL_TRACES_EXPORTER="${OTEL_TRACES_EXPORTER:-otlp}"
  export OTEL_METRICS_EXPORTER="${OTEL_METRICS_EXPORTER:-none}"
  export OTEL_LOGS_EXPORTER="${OTEL_LOGS_EXPORTER:-none}"
fi

# --- Full override via JAVA_OPTS -----------------------------------------
# Если пользователь задал JAVA_OPTS — он берёт всю ответственность на себя.
# Иначе склеиваем сами.
if [ -n "${JAVA_OPTS:-}" ]; then
  FINAL_OPTS="${JAVA_OPTS}"
else
  FINAL_OPTS="${HEAP_OPTS} ${GC_OPTS} ${SAFETY_OPTS} ${EXTRA_OPTS}"
fi

# --- Logging ------------------------------------------------------------
echo "[pinot-launcher] role=${PINOT_ROLE:-?} cmd=${ROLE_CMD}"
echo "[pinot-launcher] heap=${HEAP_MIN}/${HEAP_MAX} direct=${DIRECT_MEM:-default}"
echo "[pinot-launcher] gc_profile=${GC_PROFILE} gc_opts=${GC_OPTS}"
echo "[pinot-launcher] jmx=$([ -n "${JMX_OPTS}" ] && echo "on:${JMX_PORT}" || echo "off")"
echo "[pinot-launcher] otel=$([ -n "${OTEL_OPTS}" ] && echo "on:${OTEL_EXPORTER_OTLP_ENDPOINT}" || echo "off")"
echo "[pinot-launcher] config=${PINOT_CONFIG}"

# shellcheck disable=SC2086
exec java \
  ${FINAL_OPTS} \
  ${JMX_OPTS} \
  ${OTEL_OPTS} \
  -cp "/opt/pinot/lib/*:/opt/pinot/plugins/*/*.jar" \
  org.apache.pinot.tools.admin.PinotAdministrator \
  "${ROLE_CMD}" \
  -configFileName "${PINOT_CONFIG}"
