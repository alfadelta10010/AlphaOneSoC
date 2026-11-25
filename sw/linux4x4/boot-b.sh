cd ~/v13/out
stdbuf -oL ~/swb5/build/sw/bench/sim +FLASH_FILE=$HOME/v13/out/c0-bench-flash.hex +UART_DIV=29 +UART_IN=$HOME/v13/in-b.hex +MAX_CYCLES=6000000000 > ~/v13/boot-b.log 2>&1
echo EXIT $? >> ~/v13/boot-b.log
