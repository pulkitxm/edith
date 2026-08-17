use std::error::Error;

use chrono::{DateTime, Utc};
use serde::Serialize;
use serde_json::{Value, json};
use sqlx::PgPool;
use tokio::process::Command;
use uuid::Uuid;

pub const PROBE_SCRIPT: &str = r#"
os=$(uname -s | tr 'A-Z' 'a-z')
arch=$(uname -m)
case "$arch" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; esac
docker=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo none)
compose=$(docker compose version --short 2>/dev/null || echo none)
gpu_vendor=none; gpu_model=; vram=0
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
  gpu_vendor=nvidia
  gpu_model=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
  vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)
elif command -v rocm-smi >/dev/null 2>&1; then
  gpu_vendor=amd; gpu_model=$(rocm-smi --showproductname 2>/dev/null | head -1)
elif [ "$os" = darwin ] && [ "$arch" = arm64 ]; then
  gpu_vendor=apple; gpu_model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
fi
if [ "$os" = darwin ]; then
  cores=$(sysctl -n hw.ncpu); ram=$(( $(sysctl -n hw.memsize) / 1048576 ))
else
  cores=$(nproc); ram=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 ))
fi
disk=$(df -Pm . | awk 'NR==2 {print $4}')
gpu_runtime=no
if [ "$gpu_vendor" = nvidia ] && docker run --rm --gpus all busybox true >/dev/null 2>&1; then
  gpu_runtime=yes
fi
ports=
for port in 4820 5432 6379 8081 11434; do
  if command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 $port >/dev/null 2>&1; then
    ports="$ports $port"
  fi
done
printf '{"os":"%s","arch":"%s","docker":"%s","compose":"%s","gpuVendor":"%s","gpuModel":"%s","vramMb":%s,"cpuCores":%s,"ramMb":%s,"diskFreeMb":%s,"gpuRuntime":"%s","portsTaken":"%s"}\n' \
  "$os" "$arch" "$docker" "$compose" "$gpu_vendor" "$gpu_model" "${vram:-0}" "$cores" "$ram" "$disk" "$gpu_runtime" "$ports"
"#;

#[derive(Debug, Serialize, sqlx::FromRow)]
#[serde(rename_all = "camelCase")]
pub struct MachineRow {
    pub id: Uuid,
    pub name: String,
    pub transport: String,
    pub endpoint: String,
    pub os: Option<String>,
    pub arch: Option<String>,
    pub gpu_vendor: Option<String>,
    pub gpu_model: Option<String>,
    pub vram_mb: Option<i32>,
    pub cpu_cores: Option<i32>,
    pub ram_mb: Option<i32>,
    pub disk_free_mb: Option<i32>,
    pub profile: Option<String>,
    pub profile_override: Option<String>,
    pub status: String,
    pub last_seen: Option<DateTime<Utc>>,
    pub capabilities: Value,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlacementRow {
    pub machine: String,
    pub service: String,
    pub role: &'static str,
    pub enabled: bool,
    pub notes: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Plan {
    pub placements: Vec<PlacementRow>,
    pub warnings: Vec<String>,
    pub compose: Vec<String>,
}

pub fn derive_profile(
    os: &str,
    arch: &str,
    gpu_vendor: &str,
    vram_mb: i64,
    gpu_runtime_ok: bool,
) -> &'static str {
    match gpu_vendor {
        "nvidia" | "amd" if vram_mb >= 24_000 && gpu_runtime_ok => "gpu-large",
        "nvidia" | "amd" if vram_mb >= 8_000 && gpu_runtime_ok => "gpu-small",
        "apple" if os == "darwin" && arch == "arm64" => "apple-metal",
        _ => "cpu-only",
    }
}

pub fn models_for(profile: &str) -> Value {
    match profile {
        "gpu-large" => json!({
            "stt": "whisper-large-v3",
            "vision": "qwen3-vl:8b",
            "embedding": "qwen3-embedding:0.6b",
            "rerank": "qwen3-reranker:0.6b",
            "note": "everything in-container with the GPU passed through",
        }),
        "gpu-small" => json!({
            "stt": "whisper-large-v3",
            "vision": "qwen3-vl:4b",
            "embedding": "qwen3-embedding:0.6b",
            "rerank": "qwen3-reranker:0.6b",
            "note": "in-container, mid sized vision model",
        }),
        "apple-metal" => json!({
            "stt": "parakeet-mlx for english, whisper.cpp large-v3 for hindi",
            "vision": "qwen3-vl:8b",
            "embedding": "qwen3-embedding:0.6b",
            "rerank": "qwen3-reranker:0.6b",
            "note": "model services run host-native on launchd, reached over host.docker.internal",
        }),
        _ => json!({
            "stt": "whisper.cpp base, or a remote endpoint",
            "vision": "qwen3-vl:2b, slowly",
            "embedding": "qwen3-embedding:0.6b",
            "rerank": "none, fusion order is kept",
            "note": "this works, it is just slow; adding a machine with a GPU is the fix",
        }),
    }
}

pub fn profile_warnings(profile: &str, disk_free_mb: i64, ports_taken: &str) -> Vec<String> {
    let mut warnings = Vec::new();
    if profile == "cpu-only" {
        warnings.push(
            "This machine has no usable GPU, so transcription and captioning will be slow. It \
             will still work. Adding a machine with a GPU is what fixes it."
                .to_owned(),
        );
    }
    if profile == "apple-metal" {
        warnings.push(
            "Docker on macOS cannot reach the GPU, so the model services run on the host and the \
             containers reach them over host.docker.internal."
                .to_owned(),
        );
    }
    if disk_free_mb > 0 && disk_free_mb < 40_000 {
        warnings.push(format!(
            "Only {disk_free_mb}MB free. A backfill will fill that; clear space before starting."
        ));
    }
    if !ports_taken.trim().is_empty() {
        warnings.push(format!(
            "These ports are already in use and will need remapping:{ports_taken}"
        ));
    }
    warnings
}

pub fn compose_files(profile: &str) -> Vec<String> {
    let mut files = vec!["compose.yaml".to_owned()];
    match profile {
        "gpu-large" | "gpu-small" => files.push("compose.gpu.yaml".to_owned()),
        "apple-metal" => files.push("compose.mac.yaml".to_owned()),
        _ => files.push("compose.cpu.yaml".to_owned()),
    }
    files
}

pub async fn add(
    pool: &PgPool,
    name: &str,
    transport: &str,
    endpoint: &str,
) -> Result<Uuid, sqlx::Error> {
    sqlx::query_scalar::<_, Uuid>(
        "INSERT INTO machines (name, transport, endpoint) VALUES ($1, $2, $3) ON CONFLICT (name) DO UPDATE SET transport = EXCLUDED.transport, endpoint = EXCLUDED.endpoint RETURNING id",
    )
    .bind(name)
    .bind(transport)
    .bind(endpoint)
    .fetch_one(pool)
    .await
}

pub async fn list(pool: &PgPool) -> Result<Vec<MachineRow>, sqlx::Error> {
    sqlx::query_as::<_, MachineRow>(
        "SELECT id, name, transport, endpoint, os, arch, gpu_vendor, gpu_model, vram_mb, cpu_cores, ram_mb, disk_free_mb, profile, profile_override, status, last_seen, capabilities FROM machines ORDER BY added_at",
    )
    .fetch_all(pool)
    .await
}

pub async fn run_probe(transport: &str, endpoint: &str) -> Result<Value, String> {
    let output = match transport {
        "ssh" => Command::new("ssh")
            .args(["-o", "BatchMode=yes", endpoint, "sh -s"])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .map_err(|error| error.to_string())
            .map(|mut child| {
                let stdin = child.stdin.take();
                (child, stdin)
            }),
        _ => Err("only local and ssh transports probe today".to_owned()),
    };

    if transport == "local" || transport == "context" {
        let result = Command::new("sh")
            .arg("-c")
            .arg(PROBE_SCRIPT)
            .output()
            .await
            .map_err(|error| error.to_string())?;
        return parse_probe(&String::from_utf8_lossy(&result.stdout));
    }

    let (child, stdin) = output?;
    if let Some(mut stdin) = stdin {
        use tokio::io::AsyncWriteExt;
        stdin
            .write_all(PROBE_SCRIPT.as_bytes())
            .await
            .map_err(|error| error.to_string())?;
        drop(stdin);
    }
    let result = child
        .wait_with_output()
        .await
        .map_err(|error| error.to_string())?;
    if !result.status.success() {
        return Err(String::from_utf8_lossy(&result.stderr).trim().to_owned());
    }
    parse_probe(&String::from_utf8_lossy(&result.stdout))
}

pub fn parse_probe(output: &str) -> Result<Value, String> {
    let line = output
        .lines()
        .rev()
        .find(|line| line.trim_start().starts_with('{'))
        .ok_or_else(|| format!("the probe printed nothing usable: {output}"))?;
    serde_json::from_str::<Value>(line.trim())
        .map_err(|error| format!("the probe output was not JSON: {error}"))
}

pub async fn probe(pool: &PgPool, name: &str) -> Result<MachineRow, Box<dyn Error + Send + Sync>> {
    let Some((id, transport, endpoint)) = sqlx::query_as::<_, (Uuid, String, String)>(
        "SELECT id, transport, endpoint FROM machines WHERE name = $1",
    )
    .bind(name)
    .fetch_optional(pool)
    .await?
    else {
        return Err(format!("no machine named {name}").into());
    };

    let capabilities = run_probe(&transport, &endpoint).await?;
    let read_str = |key: &str| {
        capabilities
            .get(key)
            .and_then(Value::as_str)
            .map(str::to_owned)
    };
    let read_int = |key: &str| {
        capabilities
            .get(key)
            .and_then(Value::as_i64)
            .or_else(|| {
                capabilities
                    .get(key)
                    .and_then(Value::as_str)
                    .and_then(|value| value.trim().parse::<i64>().ok())
            })
            .unwrap_or(0)
    };

    let os = read_str("os").unwrap_or_default();
    let arch = read_str("arch").unwrap_or_default();
    let gpu_vendor = read_str("gpuVendor").unwrap_or_else(|| "none".to_owned());
    let vram = read_int("vramMb");
    let runtime_ok = read_str("gpuRuntime").as_deref() == Some("yes");
    let profile = derive_profile(&os, &arch, &gpu_vendor, vram, runtime_ok);

    sqlx::query(
        "UPDATE machines SET os = $2, arch = $3, docker_version = $4, compose_version = $5, gpu_vendor = $6, gpu_model = $7, vram_mb = $8, cpu_cores = $9, ram_mb = $10, disk_free_mb = $11, capabilities = $12, profile = $13, status = 'ready', last_seen = now() WHERE id = $1",
    )
    .bind(id)
    .bind(&os)
    .bind(&arch)
    .bind(read_str("docker"))
    .bind(read_str("compose"))
    .bind(&gpu_vendor)
    .bind(read_str("gpuModel"))
    .bind(vram as i32)
    .bind(read_int("cpuCores") as i32)
    .bind(read_int("ramMb") as i32)
    .bind(read_int("diskFreeMb") as i32)
    .bind(&capabilities)
    .bind(profile)
    .execute(pool)
    .await?;

    list(pool)
        .await?
        .into_iter()
        .find(|machine| machine.name == name)
        .ok_or_else(|| "the machine vanished mid probe".into())
}

pub async fn plan(pool: &PgPool) -> Result<Plan, sqlx::Error> {
    let machines = list(pool).await?;
    let mut placements = Vec::new();
    let mut warnings = Vec::new();
    let mut compose = Vec::new();

    if machines.is_empty() {
        warnings.push(
            "No machines are registered yet. Adding this one is the whole of a single machine \
             setup and it needs no decisions."
                .to_owned(),
        );
        return Ok(Plan {
            placements,
            warnings,
            compose,
        });
    }

    let core = machines
        .iter()
        .max_by_key(|machine| machine.ram_mb.unwrap_or(0))
        .map(|machine| machine.name.clone())
        .unwrap_or_default();
    let model_host = machines
        .iter()
        .max_by_key(|machine| machine.vram_mb.unwrap_or(0))
        .map(|machine| machine.name.clone())
        .unwrap_or_else(|| core.clone());

    for machine in &machines {
        let profile = machine
            .profile_override
            .clone()
            .or_else(|| machine.profile.clone())
            .unwrap_or_else(|| "cpu-only".to_owned());
        for file in compose_files(&profile) {
            if !compose.contains(&file) {
                compose.push(file);
            }
        }
        let ports = machine
            .capabilities
            .get("portsTaken")
            .and_then(Value::as_str)
            .unwrap_or_default();
        warnings.extend(profile_warnings(
            &profile,
            machine.disk_free_mb.unwrap_or(0) as i64,
            ports,
        ));

        if machine.name == core {
            for service in ["postgres", "redis", "api"] {
                placements.push(PlacementRow {
                    machine: machine.name.clone(),
                    service: service.to_owned(),
                    role: "core",
                    enabled: true,
                    notes: "everything else points at this one".to_owned(),
                });
            }
        }
        if machine.name == model_host {
            for service in ["stt", "vision", "embedding", "rerank"] {
                placements.push(PlacementRow {
                    machine: machine.name.clone(),
                    service: service.to_owned(),
                    role: "models",
                    enabled: true,
                    notes: format!("{profile}: {}", models_for(&profile)["note"]),
                });
            }
        }
        placements.push(PlacementRow {
            machine: machine.name.clone(),
            service: "workers".to_owned(),
            role: "workers",
            enabled: true,
            notes: "stateless, runs wherever there is capacity".to_owned(),
        });
    }

    for placement in &placements {
        let Some(machine) = machines
            .iter()
            .find(|machine| machine.name == placement.machine)
        else {
            continue;
        };
        sqlx::query(
            "INSERT INTO placements (machine_id, service, notes) VALUES ($1, $2, $3) ON CONFLICT (machine_id, service) DO UPDATE SET notes = EXCLUDED.notes",
        )
        .bind(machine.id)
        .bind(&placement.service)
        .bind(&placement.notes)
        .execute(pool)
        .await?;
    }

    if machines.len() > 1 {
        warnings.push(
            "Compose is a single host tool, so this is one stack per machine wired together by \
             URLs. Bind the database to a private or WireGuard address, never to 0.0.0.0."
                .to_owned(),
        );
    }

    Ok(Plan {
        placements,
        warnings,
        compose,
    })
}

pub async fn set_profile(pool: &PgPool, name: &str, profile: &str) -> Result<bool, sqlx::Error> {
    let updated = sqlx::query("UPDATE machines SET profile_override = $2 WHERE name = $1")
        .bind(name)
        .bind(profile)
        .execute(pool)
        .await?;
    Ok(updated.rows_affected() > 0)
}

#[cfg(test)]
mod tests {
    use super::{compose_files, derive_profile, models_for, parse_probe, profile_warnings};

    #[test]
    fn a_big_card_with_a_working_runtime_is_the_large_tier() {
        assert_eq!(
            derive_profile("linux", "amd64", "nvidia", 24_576, true),
            "gpu-large"
        );
        assert_eq!(
            derive_profile("linux", "amd64", "nvidia", 12_288, true),
            "gpu-small"
        );
    }

    #[test]
    fn a_card_whose_runtime_does_not_work_is_not_a_gpu_machine() {
        assert_eq!(
            derive_profile("linux", "amd64", "nvidia", 24_576, false),
            "cpu-only"
        );
    }

    #[test]
    fn apple_silicon_runs_its_models_on_the_host() {
        assert_eq!(
            derive_profile("darwin", "arm64", "apple", 0, false),
            "apple-metal"
        );
        assert!(compose_files("apple-metal").contains(&"compose.mac.yaml".to_owned()));
        assert!(
            models_for("apple-metal")["note"]
                .as_str()
                .unwrap()
                .contains("host-native")
        );
    }

    #[test]
    fn the_cpu_tier_warns_loudly_and_still_boots() {
        let warnings = profile_warnings("cpu-only", 500_000, "");
        assert_eq!(warnings.len(), 1);
        assert!(warnings[0].contains("still work"));
    }

    #[test]
    fn a_full_disk_and_a_taken_port_are_both_called_out() {
        let warnings = profile_warnings("gpu-large", 10_000, " 5432");
        assert!(warnings.iter().any(|warning| warning.contains("10000MB")));
        assert!(warnings.iter().any(|warning| warning.contains("5432")));
    }

    #[test]
    fn probe_output_is_read_off_the_last_json_line() {
        let output = "warning: something\n{\"os\":\"linux\",\"vramMb\":24576}\n";
        let value = parse_probe(output).unwrap();
        assert_eq!(value["os"], "linux");
        assert!(parse_probe("nothing here").is_err());
    }
}
