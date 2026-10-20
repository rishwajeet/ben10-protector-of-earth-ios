#include "protector/menu_input.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
int main(void) {
    ProtectorMenuInput state = {0};
#define SAMPLE(x,y,a,b,t) protector_menu_input_sample(&state,x,y,a,b,t)
    assert(SAMPLE(0,0,0,0,0) == PROTECTOR_MENU_NONE);
    assert(SAMPLE(.54,0,0,0,0) == PROTECTOR_MENU_NONE);
    assert(SAMPLE(.56,0,0,0,0) == PROTECTOR_MENU_RIGHT);
    assert(SAMPLE(.4,0,0,0,.37) == PROTECTOR_MENU_NONE);
    assert(SAMPLE(.4,0,0,0,.38) == PROTECTOR_MENU_RIGHT);
    assert(SAMPLE(.4,0,0,0,.49) == PROTECTOR_MENU_NONE);
    assert(SAMPLE(.4,0,0,0,.50) == PROTECTOR_MENU_RIGHT);
    assert(SAMPLE(.34,0,0,0,.51) == PROTECTOR_MENU_NONE);
    assert(SAMPLE(.4,0,0,0,.6) == PROTECTOR_MENU_NONE);
    assert(SAMPLE(-1,0,0,0,1) == PROTECTOR_MENU_LEFT);
    assert(SAMPLE(1,1,0,0,2) == PROTECTOR_MENU_UP);
    assert(SAMPLE(0,-1,0,0,3) == PROTECTOR_MENU_DOWN);
    assert(SAMPLE(0,0,1,0,4) == PROTECTOR_MENU_CONFIRM);
    assert(SAMPLE(0,0,1,0,6) == PROTECTOR_MENU_NONE);
    assert(SAMPLE(0,0,0,0,7) == PROTECTOR_MENU_NONE);
    assert(SAMPLE(0,0,1,1,8) == PROTECTOR_MENU_BACK);
    assert(SAMPLE(0,0,1,1,9) == PROTECTOR_MENU_NONE);
    assert(SAMPLE(NAN,INFINITY,0,0,10) == PROTECTOR_MENU_NONE);
    assert(SAMPLE(1,0,0,0,11) == PROTECTOR_MENU_RIGHT);
    assert(SAMPLE(1,0,0,0,100) == PROTECTOR_MENU_RIGHT);
    assert(SAMPLE(1,0,0,0,100) == PROTECTOR_MENU_NONE);
    protector_menu_input_reset(&state);
    assert(SAMPLE(0,0,0,0,101) == PROTECTOR_MENU_NONE);
    assert(SAMPLE(0,0,1,0,102) == PROTECTOR_MENU_CONFIRM);
    assert(SAMPLE(1,0,0,0,NAN) == PROTECTOR_MENU_NONE);
    puts("menu input: thresholds, dominant axis, repeat, button edges, reset and invalid input pass");
    return 0;
}
