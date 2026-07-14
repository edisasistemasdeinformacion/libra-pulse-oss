# =============================================================================
# Libra Pulse — Imagen todo-en-uno
# =============================================================================
# Contexto de build: raíz del repositorio
#   docker build -t libra-telemetry -f single-container/Dockerfile .
#
# Incluye: Grafana 13.0.2 · Loki 3.7.2 · Prometheus v3.12.0
#          Tempo 2.9.1 · Grafana Alloy v1.16.2
# Supervisor: supervisord
# =============================================================================

# ── Fuentes: extraer binarios/assets de imágenes oficiales ───────────────────
FROM grafana/grafana:13.0.2     AS src-grafana
FROM grafana/loki:3.7.2         AS src-loki
FROM prom/prometheus:v3.12.0    AS src-prometheus
FROM grafana/tempo:2.9.1        AS src-tempo
FROM grafana/alloy:v1.16.2      AS src-alloy

# ── Runtime ───────────────────────────────────────────────────────────────────
FROM ubuntu:24.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends supervisor curl wget unzip ca-certificates nginx apache2-utils gettext-base && \
    rm -rf /var/lib/apt/lists/*

# ── Descargar y extraer configuraciones ──────────────────────────────────────
RUN wget -q \
         "https://libraupdate.libracloud.com/auto/beta/galileo/recursos_docker/libra_pulse/libra_pulse.zip" \
         -O /tmp/libra_pulse.zip && \
    unzip /tmp/libra_pulse.zip -d /tmp/libra_pulse && \
    rm /tmp/libra_pulse.zip

# ── Grafana: binario + assets web completos (el más pesado, ~400 MB) ─────────
COPY --from=src-grafana /usr/share/grafana /usr/share/grafana

# ── Binarios de los demás servicios ──────────────────────────────────────────
COPY --from=src-loki       /usr/bin/loki        /usr/local/bin/loki
COPY --from=src-prometheus /bin/prometheus      /usr/local/bin/prometheus
COPY --from=src-tempo      /tempo               /usr/local/bin/tempo
COPY --from=src-alloy      /bin/alloy           /usr/local/bin/alloy

# ── Directorios destino de configuraciones ────────────────────────────────────
RUN mkdir -p \
    /etc/alloy \
    /etc/loki \
    /etc/prometheus \
    /etc/grafana/provisioning/datasources \
    /etc/grafana/provisioning/dashboards \
    /etc/nginx/conf.d \
    /apps/resources && \
    ln -s /apps/resources /etc/grafana/provisioning/dashboards/resources

# ── Instalar todo desde el ZIP ────────────────────────────────────────────────
RUN cp /tmp/libra_pulse/configs/alloy/config.alloy \
       /etc/alloy/config.alloy && \
    cp /tmp/libra_pulse/configs/loki/loki-config.yaml \
       /etc/loki/local-config.yaml && \
    cp /tmp/libra_pulse/configs/prometheus/prometheus.yml \
       /etc/prometheus/prometheus.yml && \
    cp /tmp/libra_pulse/configs/tempo/tempo-config.yaml \
       /etc/tempo.yaml && \
    cp /tmp/libra_pulse/configs/grafana/provisioning/datasources/datasources.yaml \
       /etc/grafana/provisioning/datasources/datasources.yaml && \
    cp -r /tmp/libra_pulse/configs/grafana/provisioning/dashboards/. \
       /etc/grafana/provisioning/dashboards/ && \    
    cp /tmp/libra_pulse/supervisord.conf \
       /etc/supervisor/conf.d/libra-pulse.conf && \
    cp /tmp/libra_pulse/entrypoint.sh \
       /entrypoint.sh && \
    sed -i 's/\r//' /entrypoint.sh && \
    chmod +x /entrypoint.sh && \
    cp /tmp/libra_pulse/configs/grafana/assets/edisa_logo.png \
       /usr/share/grafana/public/img/edisa-icono-azul.png && \
    cp /tmp/libra_pulse/configs/grafana/assets/libra_logo.png \
       /usr/share/grafana/public/img/libra-logo-azul.png && \
    B64_ICONO=$(base64 -w0 /usr/share/grafana/public/img/edisa-icono-azul.png) && \
    B64_LOGO=$(base64 -w0 /usr/share/grafana/public/img/libra-logo-azul.png) && \
    cp /usr/share/grafana/public/img/grafana_icon.svg \
       /usr/share/grafana/public/img/grafana_original.svg && \
    printf '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 60"><image href="data:image/png;base64,%s" width="200" height="60" preserveAspectRatio="xMidYMid meet"/></svg>' "$B64_LOGO" \
        > /usr/share/grafana/public/img/grafana_icon.svg && \
    cp /usr/share/grafana/public/img/edisa-icono-azul.png \
       /usr/share/grafana/public/img/fav32.png && \
    cp /usr/share/grafana/public/img/edisa-icono-azul.png \
       /usr/share/grafana/public/build/img/fav32.png && \
    cp /usr/share/grafana/public/img/edisa-icono-azul.png \
       /usr/share/grafana/public/img/apple-touch-icon.png && \
    printf '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 55 55"><image href="data:image/png;base64,%s" width="55" height="55" preserveAspectRatio="xMidYMid meet"/></svg>' "$B64_ICONO" \
        > /usr/share/grafana/public/img/grafana_icon_nav.svg && \
    grep -rl 'src:r,alt:"Grafana"' /usr/share/grafana/public/build/ | \
        xargs --no-run-if-empty sed -i 's|src:r,alt:"Grafana"|src:"public/img/grafana_icon_nav.svg",alt:"Grafana"|g' && \
    grep -rl 'LoginTitle="Welcome to Grafana"' /usr/share/grafana/public/build/ | \
        xargs --no-run-if-empty sed -i 's/LoginTitle="Welcome to Grafana"/LoginTitle="Welcome to Pulse"/g' && \
    grep -rl 'AppTitle="Grafana"' /usr/share/grafana/public/build/ | \
        xargs --no-run-if-empty sed -i 's/AppTitle="Grafana"/AppTitle="Libra Pulse"/g' && \
    grep -rlF 'src:`${x||r}`,alt:"Grafana"' /usr/share/grafana/public/build/ | \
        xargs --no-run-if-empty sed -i 's#src:`\${x||r}`,alt:"Grafana"#src:`${x||"public/img/grafana_icon.svg"}`,alt:"Grafana"#g' && \
    grep -rl 'GetLoginSubTitle=()=>null' /usr/share/grafana/public/build/ | \
        xargs --no-run-if-empty sed -i 's#GetLoginSubTitle=()=>null#GetLoginSubTitle=()=>(0,t.jsxs)("span",{children:["Libra Pulse v0.0.0",(0,t.jsx)("br",{}),"Powered by Grafana ",(0,t.jsx)("img",{src:"public/img/grafana_original.svg",style:{height:"14px",verticalAlign:"middle"},alt:"Grafana"})]})#g' && \
    grep -rl 'url:"https://community.grafana.com/?utm_source=grafana_footer"}];function' /usr/share/grafana/public/build/ | \
        xargs --no-run-if-empty sed -i 's#url:"https://community.grafana.com/?utm_source=grafana_footer"}];function#url:"https://community.grafana.com/?utm_source=grafana_footer"},{target:"_blank",id:"opensource",text:"Open Source - Pulse (AGPLv3)",icon:"github",url:"https://github.com/edisasistemasdeinformacion/libra-pulse-oss"}];function#g' && \
    sed -i 's/\[\[\.AppTitle\]\]/Libra Pulse/g' /usr/share/grafana/public/views/index.html && \
    sed -i "s|url('[^']*LoadingLogo[^']*')|url('public/img/edisa-icono-azul.png')|g" /usr/share/grafana/public/views/index.html && \
    sed -i 's/aria-label="Loading Grafana"/aria-label="Loading Libra Pulse"/g' /usr/share/grafana/public/views/index.html && \
    rm -rf /tmp/libra_pulse

# ── Directorios de datos en tiempo de build ───────────────────────────────────
RUN mkdir -p \
    /data/grafana \
    /data/prometheus \
    /data/loki/chunks \
    /data/loki/rules \
    /data/loki/compactor \
    /data/tempo/blocks \
    /data/tempo/wal \
    /data/tempo/generator \
    /data/alloy \
    /var/log/galileo \
    /var/log/supervisor

# ── Usuario sin privilegios para los servicios ────────────────────────────────
RUN useradd -r -s /bin/false telemetry && \
    chown -R telemetry:telemetry \
        /data \
        /etc/alloy \
        /etc/loki \
        /etc/prometheus \
        /apps/resources \
        /var/log/galileo \
        /var/log/supervisor

# ── Volúmenes ─────────────────────────────────────────────────────────────────
# /data            → persistencia de todos los servicios
# /var/log/galileo → logs de servicios Galileo (montar read-only desde el host)
VOLUME ["/data", "/var/log/galileo"]

# ── Puertos expuestos ─────────────────────────────────────────────────────────
# 80    → Nginx (proxy → Grafana)
# 4317  → OTel gRPC (Alloy)
# 4318  → OTel HTTP (Alloy)
# 12345 → Alloy UI / self-metrics
EXPOSE 80 4317 4318 12345

ENV GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/etc/grafana/provisioning/dashboards/galileo-overview.json

LABEL com.libra.service=OTROS_SERVICIOS

ENTRYPOINT ["/entrypoint.sh"]