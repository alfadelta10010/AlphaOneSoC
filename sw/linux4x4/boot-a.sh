cd ~/v13/out
stdbuf -oL ~/swb5/build/sw/bench/sim +FLASH_FILE=$HOME/v13/out/c5-bench-flash.hex +UART_DIV=34 +UART_IN=$HOME/v13/in.hex +MAX_CYCLES=6000000000 > ~/v13/boot-a.log 2>&1
echo EXIT $? >> ~/v13/boot-a.log
