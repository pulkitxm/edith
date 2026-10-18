#pragma once
#include <stdbool.h>
#include <stdint.h>
void renderer_audit_begin(void);
void renderer_audit_end(void);
uint32_t renderer_audit_process_calls(void);
uint32_t renderer_audit_pty_calls(void);
bool renderer_audit_probe(void);
