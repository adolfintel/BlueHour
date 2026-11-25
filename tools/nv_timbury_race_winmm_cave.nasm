BITS 32
ORG 0x0a000000


creation_hook:
  cmp dword [creation_count], 120
  jae creation_run
  inc dword [creation_count]
  mov [tmp_edi], EDI
  mov [tmp_ebx], EBX
  pushad
  mov eax, [tmp_edi]
  test eax, eax
  jz creation_log_fields
  mov ecx, [eax+0x00]
  mov [rec_creation+12], ecx
  mov ecx, [eax+0x04]
  mov [rec_creation+16], ecx
  mov ecx, [eax+0x08]
  mov [rec_creation+20], ecx
  mov ecx, [eax+0x0c]
  mov [rec_creation+24], ecx
  mov ecx, [eax+0x10]
  mov [rec_creation+28], ecx
  mov ecx, [eax+0x14]
  mov [rec_creation+32], ecx
  mov ecx, [eax+0x18]
  mov [rec_creation+36], ecx
creation_log_fields:
  mov ecx, [tmp_edi]
  mov [rec_creation+8], ecx
  mov ecx, [tmp_ebx]
  mov [rec_creation+4], ecx
  push 40
  push rec_creation
  call log_write
  popad

creation_run:
  mov eax, [ESI+0x7c]
  mov eax, [EAX+EBX*4]
  push eax
  push EDI
  jmp 0x0041a50a

upstream_hook:
  cmp dword [sleep_enable], 0
  je upstream_nosleep
  cmp dword [sleep_calls], 0
  je upstream_nosleep
  mov eax, dword [sleep_count]
  cmp eax, dword [sleep_calls]
  jae upstream_nosleep
  inc dword [sleep_count]
  pushfd
  fxsave dword [cpu_state]
  pushad
  push dword [sleep_ms]
  call dword [sleep_addr]
  popad
  fxrstor dword [cpu_state]
  popfd
upstream_nosleep:
  cmp dword [upstream_count], 2000
  jae upstream_run
  inc dword [upstream_count]
  mov [tmp_ecx], ECX
  mov [tmp_esi], ESI
  mov [tmp_edx], EDX

  mov eax, [ESP+0x04]
  mov [rec_upstream+20], eax
  mov eax, [ESP+0x24]
  mov [rec_upstream+24], eax
  mov eax, [ESP+0x28]
  mov [rec_upstream+28], eax
  mov eax, [ESP+0x2c]
  mov [rec_upstream+32], eax

  call dword [tick_addr]
  mov [rec_upstream+36], eax

  pushad
  mov eax, [tmp_ecx]
  mov [rec_upstream+8], eax
  mov eax, [tmp_esi]
  mov [rec_upstream+12], eax
  mov eax, [tmp_edx]
  mov [rec_upstream+16], eax
  mov eax, [upstream_count]
  mov [rec_upstream+4], eax
  push 40
  push rec_upstream
  call log_write
  popad

upstream_run:
  fld dword [ESP+0x04]
  fmul dword [ESP+0x04]
  jmp 0x00421864

dist_hook:
  cmp dword [dist_count], 2000
  jae dist_run
  inc dword [dist_count]
  stmxcsr dword [rec_dist+36]

  cmp dword [stack_log_count], 50
  jae dist_no_stack_log
  inc dword [stack_log_count]
  mov eax, [dist_count]
  mov [rec_stack+4], eax
  mov [rec_stack2+4], eax

  mov eax, [ESP+0x00]
  mov [rec_stack+8], eax
  mov eax, [ESP+0x04]
  mov [rec_stack+12], eax
  mov eax, [ESP+0x08]
  mov [rec_stack+16], eax
  mov eax, [ESP+0x0c]
  mov [rec_stack+20], eax
  mov eax, [ESP+0x10]
  mov [rec_stack+24], eax
  mov eax, [ESP+0x14]
  mov [rec_stack+28], eax
  mov eax, [ESP+0x18]
  mov [rec_stack+32], eax
  mov eax, [ESP+0x1c]
  mov [rec_stack+36], eax
  push 40
  push rec_stack
  call log_write

  mov eax, [ESP+0x20]
  mov [rec_stack2+8], eax
  mov eax, [ESP+0x24]
  mov [rec_stack2+12], eax
  mov eax, [ESP+0x28]
  mov [rec_stack2+16], eax
  mov eax, [ESP+0x2c]
  mov [rec_stack2+20], eax
  mov eax, [ESP+0x30]
  mov [rec_stack2+24], eax
  mov eax, [ESP+0x34]
  mov [rec_stack2+28], eax
  mov eax, [ESP+0x38]
  mov [rec_stack2+32], eax
  mov eax, [ESP+0x3c]
  mov [rec_stack2+36], eax
  push 40
  push rec_stack2
  call log_write

dist_no_stack_log:
  mov eax, [ESP+0x38]
  mov [tmp_bug], eax
  mov eax, [ESP+0x28]
  mov [tmp_inv], eax
  mov eax, [ESP+0x24]
  mov [tmp_v1], eax
  mov eax, [ESP+0x20]
  mov [tmp_v2], eax
  mov eax, [ESP+0x04]
  mov [tmp_mult], eax
  pushad
  mov eax, [tmp_bug]
  mov [rec_dist+4], eax
  mov eax, [tmp_inv]
  mov [rec_dist+8], eax
  mov eax, [tmp_v1]
  mov [rec_dist+12], eax
  mov eax, [tmp_v2]
  mov [rec_dist+16], eax
  mov eax, [tmp_mult]
  mov [rec_dist+20], eax
  mov eax, [tmp_bug]
  test eax, eax
  jz dist_log_ptr_zero
  mov eax, [tmp_bug]
  mov ecx, [eax+0x00]
  mov [rec_dist+24], ecx
  mov ecx, [eax+0x04]
  mov [rec_dist+28], ecx
  mov ecx, [eax+0x08]
  mov [rec_dist+32], ecx
dist_log_ptr_zero:
  push 40
  push rec_dist
  call log_write
  popad

dist_run:
  fld dword [ESP+0x28]
  fmul dword [ESP+0x04]
  jmp 0x00421964

transform_hook:
  cmp dword [transform_count], 2000
  jae transform_call
  inc dword [transform_count]
  mov [tmp_ecx], ECX
  mov [tmp_edi], EDI
  mov eax, [ESP+0x04]
  mov [tmp_node], eax
  pushad
  mov eax, [tmp_edi]
  mov [rec_transform+4], eax
  mov eax, [tmp_ecx]
  mov [rec_transform+8], eax
  mov eax, [tmp_node]
  mov [rec_transform+24], eax
  mov eax, [tmp_ecx]
  test eax, eax
  jz transform_log_ptr_zero
  mov ecx, [eax+0x00]
  mov [rec_transform+12], ecx
  mov ecx, [eax+0x04]
  mov [rec_transform+16], ecx
  mov ecx, [eax+0x08]
  mov [rec_transform+20], ecx
  mov ecx, [eax+0x0c]
  mov [rec_transform+28], ecx
  mov ecx, [eax+0x10]
  mov [rec_transform+32], ecx
  mov ecx, [eax+0x14]
  mov [rec_transform+36], ecx
transform_log_ptr_zero:
  push 40
  push rec_transform
  call log_write
  popad

transform_call:
  call 0x0040f9a0
  jmp 0x0041a81f

log_write:
  push ebp
  mov ebp, esp
  pushfd
  fxsave dword [cpu_state]
  pushad
  mov eax, [log_handle]
  cmp eax, 0
  jne log_write_try
  push 0
  push 0
  push 2
  push 0
  push 2
  push 0x40000000
  push log_path
  call dword [createfile_addr]
  mov [log_handle], eax
  cmp eax, -1
  je log_write_done
log_write_try:
  cmp dword [log_handle], -1
  je log_write_done
  push 0
  push 0
  push dword [ebp+12]
  push dword [ebp+8]
  push dword [log_handle]
  call dword [writefile_addr]
log_write_done:
  popad
  fxrstor dword [cpu_state]
  popfd
  pop ebp
  ret 8

log_path:
  db "C:\\buglog_hardware.bin",0

createfile_addr: dd 0
writefile_addr: dd 0
sleep_addr: dd 0
sleep_enable: dd 0
sleep_ms: dd 0
tick_addr: dd 0
sleep_calls: dd 0
sleep_count: dd 0
creation_count: dd 0
dist_count: dd 0
transform_count: dd 0
upstream_count: dd 0
stack_log_count: dd 0
log_handle: dd 0
tmp_edi: dd 0
tmp_ebx: dd 0
tmp_ecx: dd 0
tmp_esi: dd 0
tmp_edx: dd 0
tmp_bug: dd 0
tmp_inv: dd 0
tmp_v1: dd 0
tmp_v2: dd 0
tmp_mult: dd 0
tmp_node: dd 0
align 16
cpu_state: times 512 db 0

rec_creation:
  dd 1
  dd 0,0,0,0,0,0,0,0,0

rec_dist:
  dd 2
  dd 0,0,0,0,0,0,0,0,0

rec_transform:
  dd 3
  dd 0,0,0,0,0,0,0,0,0

rec_upstream:
  dd 22
  dd 0,0,0,0,0,0,0,0,0

rec_stack:
  dd 20
  dd 0,0,0,0,0,0,0,0,0

rec_stack2:
  dd 21
  dd 0,0,0,0,0,0,0,0,0
