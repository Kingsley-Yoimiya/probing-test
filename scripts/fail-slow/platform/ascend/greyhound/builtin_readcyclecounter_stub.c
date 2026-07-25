/* Provide missing ELF symbol from broken Rbeast aarch64 wheels. */
unsigned long __builtin_readcyclecounter(void) {
  unsigned long val = 0;
#if defined(__aarch64__)
  __asm__ volatile("mrs %0, cntvct_el0" : "=r"(val));
#else
  val = 0;
#endif
  return val;
}
