import re
from pathlib import Path

import yaml


def _deep_merge(source, destination):
		"""Inspired by https://stackoverflow.com/a/20666342"""
		for key, value in source.items():
				dst_value = destination.get(key)

				if isinstance(value, dict) and isinstance(dst_value, dict):
						_deep_merge(value, dst_value)
				else:
						destination[key] = value

		return destination


def _load_yaml():
		extraConfigBase = Path("/run/config/extra")
		configFiles = [Path("/run/config/netbox/netbox.yaml")]

		configFiles.extend(sorted(extraConfigBase.glob("*/*.yaml")))

		for configFile in configFiles:
				with open(configFile, "r") as f:
						config = yaml.safe_load(f)

				_deep_merge(config, globals())


def _load_secret(name, key):
		path = "/run/secrets/{name}/{key}".format(name=name, key=key)
		with open(path, "r") as f:
				return f.read()


CORS_ORIGIN_REGEX_WHITELIST = list()
DATABASE = dict()
EMAIL = dict()
REDIS = dict()

_load_yaml()

DATABASE["PASSWORD"] = _load_secret("netbox", "db_password")
EMAIL["PASSWORD"] = _load_secret("netbox", "email_password")
REDIS["tasks"]["PASSWORD"] = _load_secret("netbox", "redis_tasks_password")
REDIS["caching"]["PASSWORD"] = _load_secret("netbox", "redis_cache_password")
SECRET_KEY = _load_secret("netbox", "secret_key")

# Post-process certain values
CORS_ORIGIN_REGEX_WHITELIST = [re.compile(r) for r in CORS_ORIGIN_REGEX_WHITELIST]
