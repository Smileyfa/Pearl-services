import logging
import os
import requests


def get_vault_secrets():
    vault_addr = os.environ.get("VAULT_ADDR")
    vault_token = os.environ.get("VAULT_TOKEN")

    # Vault is optional in development. If it is not configured, the app falls back
    # to environment variables loaded from .env or the process environment.
    if not vault_addr:
        return {}

    try:
        response = requests.get(
            f"{vault_addr}/v1/secret/data/pearlpay",
            headers={"X-Vault-Token": vault_token},
            timeout=3,
        )
        response.raise_for_status()
        return response.json()["data"]["data"]
    except Exception as exc:
        # Keep startup resilient in development: when Vault is unavailable, secrets
        # can still be provided through .env-backed environment variables.
        logging.warning("Vault unavailable, falling back to environment variables: %s", exc)
        return {}


def load_secrets():
    secrets = get_vault_secrets()

    for secret_name, secret_value in secrets.items():
        # Vault is the source of truth when available, so overwrite environment
        # values to pick up rotated secrets immediately.
        os.environ[secret_name] = str(secret_value)

    return len(secrets)
