include common.mk

deps: lux
	make clone_electric
	make -C satellite_client build
	make -C elixir_client build
	make -C prisma_example build

test_only:
	${LUX} --junit tests

test_client_only:
	${LUX} --junit tests/03*

test_only_custom:
	${LUX} --junit ${TEST}

test: deps pull test_only

pull:
	docker compose -f services_templates.yaml pull \
		postgresql

stop:
	make -C tests stop_dev_env

clean:
	rm -rf lux
	rm -rf postgres
