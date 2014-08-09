PROJECT = crawler
DEPS = cowboy lager jsx sync

dep_cowboy = git https://github.com/ninenines/cowboy 1.0.0
dep_sync = git https://github.com/rustyio/sync.git

include erlang.mk

ERLC_OPTS += +'{parse_transform, lager_transform}'

RUN := erl -pa ebin -pa deps/*/ebin -smp enable -s sync -s lager -boot start_sasl ${ERL_ARGS}
NODE ?= crawler

run: shell
shell: app
	if [ -n "${NODE}" ]; then ${RUN} -name ${NODE}@`hostname` -s crawler_app -config rel/sys.config; \
	else ${RUN} -s crawler -config rel/sys.config; \
	fi
