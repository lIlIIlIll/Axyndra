from __future__ import annotations

import re
import tempfile
from pathlib import Path
from typing import Any, Mapping

import yaml

from .provider_execution import materialize_provider_settings, provider_execution_digest
from .storage import ArtifactStore
from .util import canonical_json, sha256_bytes


PROVIDER_SETTINGS_CLOSURE_VERSION = "omp-evals-provider-settings-closure-v1"
PROVIDER_SETTINGS_MATERIALIZER_VERSION = "omp-evals-provider-settings-v1"
_FILES = ("config.yml", "providers.yml", "models.yml")
_PROFILE_ID = re.compile(r"^[A-Za-z0-9_-]+$")
_FORBIDDEN_SECRET_KEYS = {
    "api_key", "api_key_value", "authorization", "password", "secret", "token",
}


def freeze_provider_settings_closure(
    spec: Mapping[str, Any], artifacts: ArtifactStore, profile_id: str = "frozen-provider",
) -> tuple[dict[str, Any], str]:
    """Freeze the minimal product settings graph needed to replay one provider spec."""
    if not _PROFILE_ID.fullmatch(profile_id):
        raise ValueError("provider settings profile ID is invalid")
    with tempfile.TemporaryDirectory(prefix="omp-evals-provider-settings-") as raw:
        root = Path(raw)
        materialize_provider_settings(spec, root, profile_id)
        files = []
        for logical_path in _FILES:
            data = (root / logical_path).read_bytes()
            files.append({
                "logicalPath": logical_path,
                "digest": sha256_bytes(data),
                "size": len(data),
                "contentRef": artifacts.put_bytes(data),
            })
        structure = _validate_file_bytes({name: (root / name).read_bytes() for name in _FILES})
    manifest = {
        "schemaVersion": PROVIDER_SETTINGS_CLOSURE_VERSION,
        "providerExecutionDigest": provider_execution_digest(spec),
        "materializerVersion": PROVIDER_SETTINGS_MATERIALIZER_VERSION,
        "files": files,
        "defaultModelRef": structure["defaultModelRef"],
        "providerRefs": structure["providerRefs"],
        "modelRefs": structure["modelRefs"],
    }
    manifest["closureDigest"] = provider_settings_closure_digest(manifest)
    return manifest, artifacts.put_json(manifest)


def provider_settings_closure_digest(value: Mapping[str, Any]) -> str:
    canonical = dict(value)
    canonical.pop("closureDigest", None)
    return sha256_bytes(canonical_json(canonical))


def validate_provider_settings_closure(
    value: Mapping[str, Any], expected_provider_execution_digest: str | None = None,
) -> Mapping[str, Any]:
    allowed = {
        "schemaVersion", "providerExecutionDigest", "materializerVersion", "files",
        "defaultModelRef", "providerRefs", "modelRefs", "closureDigest",
    }
    if set(value) != allowed:
        missing = allowed - set(value)
        unknown = set(value) - allowed
        raise ValueError(
            "provider settings closure fields differ: missing="
            + ",".join(sorted(missing)) + " unknown=" + ",".join(sorted(unknown))
        )
    if value["schemaVersion"] != PROVIDER_SETTINGS_CLOSURE_VERSION:
        raise ValueError("unsupported provider settings closure schema")
    if value["materializerVersion"] != PROVIDER_SETTINGS_MATERIALIZER_VERSION:
        raise ValueError("unsupported provider settings materializer version")
    digest = provider_settings_closure_digest(value)
    if value["closureDigest"] != digest:
        raise ValueError("provider settings closure digest mismatch")
    if expected_provider_execution_digest is not None and (
        value["providerExecutionDigest"] != expected_provider_execution_digest
    ):
        raise ValueError("provider settings closure references another ProviderExecutionSpec")
    entries = list(value["files"])
    if [item.get("logicalPath") for item in entries] != list(_FILES):
        raise ValueError("provider settings closure must contain the canonical minimal file set")
    for item in entries:
        if set(item) != {"logicalPath", "digest", "size", "contentRef"}:
            raise ValueError("provider settings closure file entry is invalid")
        if item["contentRef"] != "sha256:" + item["digest"]:
            raise ValueError("provider settings closure content ref mismatch")
        if int(item["size"]) < 1:
            raise ValueError("provider settings closure file must not be empty")
    return value


def materialize_provider_settings_closure(
    value: Mapping[str, Any], artifacts: ArtifactStore, destination: Path,
    expected_provider_execution_digest: str | None = None,
) -> Mapping[str, Any]:
    validate_provider_settings_closure(value, expected_provider_execution_digest)
    if destination.exists() and any(destination.iterdir()):
        raise FileExistsError("provider settings destination must be empty")
    destination.mkdir(parents=True, exist_ok=True)
    loaded: dict[str, bytes] = {}
    for item in value["files"]:
        logical_path = str(item["logicalPath"])
        data = artifacts.get_bytes(str(item["contentRef"]))
        if len(data) != int(item["size"]) or sha256_bytes(data) != item["digest"]:
            raise ValueError("provider settings CAS artifact failed digest verification")
        (destination / logical_path).write_bytes(data)
        loaded[logical_path] = data
    structure = _validate_file_bytes(loaded)
    if structure["defaultModelRef"] != value["defaultModelRef"]:
        raise ValueError("provider settings default model reference changed")
    if structure["providerRefs"] != value["providerRefs"]:
        raise ValueError("provider settings provider references changed")
    if structure["modelRefs"] != value["modelRefs"]:
        raise ValueError("provider settings model references changed")
    return structure


def validate_materialized_provider_settings(root: Path) -> Mapping[str, Any]:
    return _validate_file_bytes({name: (root / name).read_bytes() for name in _FILES})


def _validate_file_bytes(files: Mapping[str, bytes]) -> Mapping[str, Any]:
    if set(files) != set(_FILES):
        raise ValueError("provider settings closure file set is incomplete")
    decoded = {name: yaml.safe_load(data.decode("utf-8")) for name, data in files.items()}
    _reject_secret_values(decoded)
    config = decoded["config.yml"]
    providers_root = decoded["providers.yml"]
    models_root = decoded["models.yml"]
    if not isinstance(config, dict) or not isinstance(config.get("default_model"), str):
        raise ValueError("config.yml must contain one textual default_model")
    providers = providers_root.get("providers") if isinstance(providers_root, dict) else None
    models = models_root.get("models") if isinstance(models_root, dict) else None
    if not isinstance(providers, list) or not providers:
        raise ValueError("providers.yml must contain provider profiles")
    if not isinstance(models, list) or not models:
        raise ValueError("models.yml must contain model entries")
    provider_ids = [str(item.get("id", "")) for item in providers if isinstance(item, dict)]
    if len(provider_ids) != len(providers) or len(set(provider_ids)) != len(provider_ids):
        raise ValueError("provider profile IDs must be present and unique")
    model_refs = []
    display_ids = []
    for item in models:
        if not isinstance(item, dict):
            raise ValueError("model catalog entries must be objects")
        model_id = str(item.get("id", ""))
        provider_id = str(item.get("provider", ""))
        if not model_id or provider_id not in provider_ids:
            raise ValueError("model references an unknown provider profile")
        display_id = provider_id + "/" + model_id
        if display_id in display_ids:
            raise ValueError("duplicate semantic model ID")
        display_ids.append(display_id)
        model_refs.append({"id": model_id, "providerRef": provider_id, "displayId": display_id})
    default_model = str(config["default_model"])
    if display_ids.count(default_model) != 1:
        raise ValueError("default_model must resolve to exactly one model entry")
    selected_model = models[display_ids.index(default_model)]
    selected_provider = next(
        item for item in providers if str(item.get("id", "")) == selected_model["provider"]
    )
    return {
        "defaultModelRef": default_model,
        "providerRefs": provider_ids,
        "modelRefs": model_refs,
        "semanticProjection": {
            "adapterIdentity": selected_provider.get("provider"),
            "protocol": selected_provider.get("protocol"),
            "baseUrl": selected_provider.get("base_url"),
            "credentialSlot": selected_provider.get("api_key_env"),
            "authentication": selected_provider.get("authentication", "api-key"),
            "timeoutMillis": selected_provider.get("timeout_millis", 120000),
            "wireModel": selected_model.get("id"),
            "contextWindowTokens": selected_model.get("context_window"),
            "maxOutputTokens": selected_model.get("max_output_tokens"),
            "reasoning": selected_model.get("reasoning"),
            "structuredOutput": selected_model.get("structured_output"),
            "promptCache": selected_model.get("prompt_cache"),
        },
    }


def _reject_secret_values(value: Any, path: str = "") -> None:
    if isinstance(value, Mapping):
        for key, item in value.items():
            name = str(key).lower()
            if name in _FORBIDDEN_SECRET_KEYS:
                raise ValueError(f"secret value is forbidden in provider settings closure: {path}{key}")
            _reject_secret_values(item, path + str(key) + ".")
    elif isinstance(value, list):
        for index, item in enumerate(value):
            _reject_secret_values(item, path + str(index) + ".")
