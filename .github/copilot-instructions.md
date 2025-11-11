# Brewblox Brewfather Service - AI Assistant Instructions

## Project Overview

This is a **Brewblox microservice** that integrates Brewfather (recipe/batch management) with Brewblox (hardware control). The service automates mash temperature control during brew days by fetching recipes from Brewfather and driving setpoint devices via MQTT/Spark API.

**Key Data Flow**: Brewfather API → Brewtracker JSON → Mash Automation → Spark Setpoint Device → MQTT Events

## Architecture & Components

### Core Modules

- **`brewfather_automation.py`** (442 lines): Main orchestrator. Implements `BrewfatherFeature` (extends `RepeaterFeature`) that:
  - Polls Brewfather API for batch/recipe updates every 30s
  - Manages mash automation state (STANDBY → HEAT → REST cycle)
  - Publishes MQTT events on `brewcast/state/brewfather` topic
  - Handles Spark connection loss/recovery
  - Key pattern: Uses `DatastoreClient` to persist state across restarts

- **`api/brewfather_api_client.py`**: Stateless Brewfather API wrapper. Credentials from `app['BREWFATHER_USER_ID']` and `app['BREWFATHER_TOKEN']` (env vars passed in `__main__.py`). Methods: `recipes()`, `batches()`, `brewtracker()`, `recipe_read()`

- **`datastore.py`**: HTTP client to Brewblox history service for persisting state. Stores/loads: settings, current state, mash steps, brew logs. Key: namespaced storage under `_namespace='brewfather'`

- **`schemas.py`**: Marshmallow schemas + dataclasses for type safety. Enums: `AutomationStage` (MASH/SPARGE/BOIL/HOPSTAND/FERMENTATION), `AutomationState` (STANDBY/HEAT/REST)

- **`__main__.py`**: Entry point. Creates aiohttp app with:
  - CLI args: `--mash-service-id` (spark-one), `--mash-setpoint-device` (HERMS MT Setpoint)
  - Sets up: scheduler, MQTT, HTTP, BrewfatherFeature

## Critical Patterns & Conventions

### 1. **RepeaterFeature Pattern**
All background tasks extend `brewblox_service.repeater.RepeaterFeature`. Lifecycle:
- `prepare()`: Async init, fetch dependencies via `features.get(app, ClassName)`
- `run()`: Called every 10s loop (sleep handles interval)
- `shutdown()`: Cleanup

### 2. **State Persistence**
State is **critical** - lost on crash. Pattern in `brewfather_automation.py`:
```python
self.datastore_client = DatastoreClient(self.app)
await self.datastore_client.store_state(state)  # On every change
await self.restore_timer()  # On reconnect
```
Always call `store_state()` after mash step transitions.

### 3. **Spark/Hardware Communication**
- `BlocksApi` from `brewblox_spark_api` manages Spark devices
- Register callback: `self.spark_client.on_blocks_change(callback)`
- Check readiness: `await self.spark_client.is_ready.wait()`
- Never drive setpoint without confirming Spark connection

### 4. **MQTT Topic Conventions**
- Publish state: `brewcast/state/{service_name}` (e.g., `brewcast/state/brewfather`)
- Subscribe: `brewcast/state/#` for all state changes
- Pattern: Structured JSON payloads with `brewtracker`, `step`, `timer` objects

### 5. **Testing Strategy**
- **Fixtures**: `conftest.py` provides `app_config`, `sys_args`, mocked MQTT/Spark clients
- **Mocking**: Use `aresponses` for HTTP, `mocker.patch()` with `AsyncMock()` for async functions
- **Test data**: `test/sample_recipe.json`, `sample_batch.json`, `sample_brewtracker.json` represent Brewfather API responses
- **Coverage**: Pytest with flake8 linting; `--cov` enabled; max line length 120

### 6. **Configuration & Secrets**
- Environment: `BREWFATHER_USER_ID`, `BREWFATHER_TOKEN` (Brewfather API credentials)
- CLI args: `--mash-service-id`, `--mash-setpoint-device`
- Don't hardcode credentials; pass via `app` dict in `__main__.py`

## Development Workflow

### Local Testing
```bash
poetry install          # Install deps
poetry run pytest       # Run tests + flake8 + coverage
poetry run pytest --cov-report=html  # See coverage report
```

### Build & Deploy
- **CI/CD**: Azure Pipelines (`azure-pipelines.yml`) on push/PR
- **Docker**: Multi-platform build (amd64, arm/v7, arm64/v8) via buildx
- **Service entry**: Docker image runs `python -m brewblox_brewfather_service` with CLI args

### Debugging
- `LOGGER = brewblox_logger(__name__)` in each module - logs appear in Brewblox service logs
- MQTT events: Subscribe to `brewcast/state/brewfather` to observe automation progress
- Datastore: Query history service datastore for stored state/settings

## Common Tasks

### Adding a New Automation Stage
1. Add enum to `AutomationStage` in `schemas.py`
2. Extend `run()` logic in `BrewfatherFeature` to handle new stage
3. Update tests in `test_brewfather_automation.py` with sample brewtracker JSON
4. Publish MQTT event: `await mqtt.publish(self.app, self.topic, state_json)`

### Integrating New Brewfather API Endpoint
1. Add method to `BrewfatherClient` in `brewfather_api_client.py`
2. Use `http.session(self.app)` for HTTP; `BasicAuth(self.userid, self.token)`
3. Mock in tests using `aresponses.ResponsesMockServer`

### Handling Connection Loss
Pattern already exists in `brewfather_automation.py`:
```python
if not self.spark_client.is_ready.is_set():
    # Handle disconnect
    self.spark_connected = False
    return
```
On reconnect, always restore state via `await self.restore_timer()`.

## Key External Dependencies

- **brewblox-service**: Framework for Brewblox microservices (app, logging, HTTP, MQTT, scheduler)
- **brewblox-spark-api**: Spark hardware API client (blocks, setpoints, MQTT bridge)
- **marshmallow**: Schema validation and serialization
- **aiohttp**: Async HTTP client/server
- **pytest-aiohttp**: Async test fixtures

## Files to Know

- `pyproject.toml`: Poetry config, Python 3.7+, GPL-3.0 license
- `poetry.toml`: Poetry settings
- `tox.ini`: Pytest config (flake8 inline, 120 char limit, coverage reporting)
- `docker/Dockerfile`: Python 3.7 slim base, poetry install, run service
- `test/`: All unit tests with sample JSON fixtures for API responses
