#include "libmc.h"

char dummy_string[128] = "C math benchmark running on RV32I core";

static int bench_poly(int n) {
    /* Compute sum_{i=1..n} (i*i + 3*i).
     * For n = 1000 the closed-form result is 335335000. */
    int acc = 0;
    for (int i = 1; i <= n; ++i) {
        acc += i * i;
        acc += 3 * i;
    }
    return acc;
}

static int bench_fib(int n) {
    /* Iterative Fibonacci; F(0)=0, F(1)=1.
     * For n = 20 the result is 6765. */
    int a = 0;
    int b = 1;
    if (n == 0) return 0;
    if (n == 1) return 1;
    for (int i = 2; i <= n; ++i) {
        int next = a + b;
        a = b;
        b = next;
    }
    return b;
}



int main(void) {
    printf("\n=== C math benchmark ===\n");
    printf("Banner: %s\n\n", dummy_string);

    /* Benchmark 1: polynomial sum */
    const int poly_n = 1000;
    const int poly_expected = 335335000;
    int poly_res = bench_poly(poly_n);
    printf("bench_poly(%d)  = %d (expected %d)\n",
           poly_n, poly_res, poly_expected);
    if (poly_res != poly_expected) {
        printf("ERROR: bench_poly mismatch!\n");
    } else {
        printf("OK: bench_poly\n");
    }

    /* Benchmark 2: Fibonacci */
    const int fib_n = 20;
    const int fib_expected = 6765;
    int fib_res = bench_fib(fib_n);
    printf("bench_fib(%d)   = %d (expected %d)\n",
           fib_n, fib_res, fib_expected);
    if (fib_res != fib_expected) {
        printf("ERROR: bench_fib mismatch!\n");
    } else {
        printf("OK: bench_fib\n");
    }

    

    printf("\nC math benchmark complete.\n");
    return 0;
}
