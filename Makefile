.PHONY: test clean

test:
	@sh tests/run_tests.sh

clean:
	@rm -rf tests/xdg
