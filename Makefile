# Developer commands — run `make help` to list these
.PHONY: help dev test unit lint docker-run clean

help:            ## show this help
	@grep -E '^[a-z-]+:.*##' Makefile | awk -F':.*## ' '{printf "  make %-12s %s\n", $$1, $$2}'

dev:             ## run the app locally with hot reload
	streamlit run streamlit_app.py

test:            ## exactly what the MR pipeline checks (run before pushing)
	ruff check .
	mypy app/
	pytest tests/unit tests/streamlit_apptest -m "not integration"

unit:            ## fast unit-test loop, stop at first failure
	pytest tests/unit -x

lint:            ## lint + type check only
	ruff check . && mypy app/

docker-run:      ## (rare) build and run the real container locally
	docker build -t reportapp:local .
	docker run --rm -p 8501:8501 -p 8000:8000 --env-file .env reportapp:local

clean:           ## remove caches
	rm -rf .pytest_cache .ruff_cache **/__pycache__
