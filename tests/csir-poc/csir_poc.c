/* Deterministic Windows-target CSIR PGO PoC.
 * Call graph: main -> hot_path_A/B -> shared_function (distinct contexts).
 * No network, no admin, quick finish, deterministic stdout.
 */
#include <stdio.h>

int shared_function(int x, int tag) {
  volatile int y = x;
  int i;
  for (i = 0; i < 64; i++) {
    y = y + tag + (y & 3);
  }
  return y;
}

int hot_path_A(int n) {
  int s = 0;
  int i;
  for (i = 0; i < n; i++) {
    s += shared_function(i, 1);
  }
  return s;
}

int hot_path_B(int n) {
  int s = 0;
  int i;
  for (i = 0; i < n; i++) {
    s += shared_function(i, 7);
  }
  return s;
}

int main(void) {
  const int n = 8000;
  int a = hot_path_A(n);
  int b = hot_path_B(n);
  printf("CSIR_POC_RESULT a=%d b=%d\n", a, b);
  if (a == b) {
    return 2;
  }
  if (a == 0 || b == 0) {
    return 3;
  }
  return 0;
}
