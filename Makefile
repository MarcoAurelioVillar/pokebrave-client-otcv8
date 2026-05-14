REPO := $(shell pwd)
LUA  := lua
PY   := python3

.PHONY: harness harness-reconnect test recordings all

all: test recordings

test:
	$(LUA) $(REPO)/tests/test_all.lua

harness:
	$(PY) $(REPO)/tools/stub_fixture.py --scenario turn_loop | \
	  $(LUA) $(REPO)/tools/harness.lua --scenario turn_loop \
	         --out $(REPO)/recordings/turn_loop.log

harness-reconnect:
	$(PY) $(REPO)/tools/stub_fixture.py --scenario reconnect | \
	  $(LUA) $(REPO)/tools/harness.lua --scenario reconnect \
	         --out $(REPO)/recordings/reconnect.log

recordings: harness harness-reconnect
