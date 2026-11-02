#!/usr/bin/env bash
set -euo pipefail

venv=${VENV:-.tools/venv}
venv_python=$venv/bin/python3
bootstrap=${PYTHON_BOOTSTRAP:-python3}
jinja2_version=${JINJA2_VERSION:-3.1.6}
python=${PYTHON:-$bootstrap}
python_set_by_user=${PYTHON_SET_BY_USER:-0}

if [[ $python_set_by_user == 1 ]]; then
  if ! python_path=$(command -v "$python" 2>/dev/null); then
    echo "error: PYTHON not found: $python" >&2
    exit 1
  fi
  if ! "$python_path" -c 'import jinja2' >/dev/null 2>&1; then
    echo "error: $python lacks jinja2; unset PYTHON to use $venv, or install jinja2 there" >&2
    exit 1
  fi
  printf 'Using PYTHON=%s (jinja2 %s)\n' \
    "$python_path" "$("$python_path" -c 'import jinja2; print(jinja2.__version__)')"
  exit 0
fi

if [[ ! -x $venv_python ]]; then
  echo "Creating $venv"
  if ! "$bootstrap" -m venv "$venv"; then
    echo "error: failed to create $venv; install Xcode CLT (macOS) or python3-venv (Debian/Ubuntu)" >&2
    exit 1
  fi
fi

if ! JINJA2_VERSION="$jinja2_version" "$venv_python" -c \
  'import os, jinja2; raise SystemExit(0 if jinja2.__version__ == os.environ["JINJA2_VERSION"] else 1)' \
  >/dev/null 2>&1; then
  echo "Installing jinja2==$jinja2_version"
  if ! "$venv_python" -m pip install --quiet --disable-pip-version-check --no-input \
    "jinja2==$jinja2_version"; then
    echo "error: failed to install jinja2; check network access or set PYTHON to an interpreter with jinja2" >&2
    exit 1
  fi
fi

printf 'Python: %s (jinja2 %s)\n' \
  "$venv_python" "$("$venv_python" -c 'import jinja2; print(jinja2.__version__)')"
