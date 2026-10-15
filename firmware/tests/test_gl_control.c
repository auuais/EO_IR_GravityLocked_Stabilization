#include <assert.h>
#include <stdio.h>
#include "gl_control.h"
#include "fpga_regs.h"
static unsigned writes, reads;
static uint8_t written, mismatch;
static HAL_StatusTypeDef write_result=HAL_OK, read_result=HAL_OK;
HAL_StatusTypeDef HAL_I2C_IsDeviceReady(I2C_HandleTypeDef *p, uint16_t a, uint32_t n, uint32_t t)
{ (void)p; (void)a; (void)n; (void)t; return HAL_OK; }
HAL_StatusTypeDef HAL_I2C_Mem_Write(I2C_HandleTypeDef *p, uint16_t a, uint16_t r, uint16_t size, uint8_t *data, uint16_t len, uint32_t t)
{
    assert(p && a==0x6c && r==0x04 && size==I2C_MEMADD_SIZE_8BIT && len==1 && t==20);
    writes++; written=*data; return write_result;
}
HAL_StatusTypeDef HAL_I2C_Mem_Read(I2C_HandleTypeDef *p, uint16_t a, uint16_t r, uint16_t size, uint8_t *data, uint16_t len, uint32_t t)
{
    assert(p && a==0x6c && r==0x04 && size==I2C_MEMADD_SIZE_8BIT && len==1 && t==20);
    reads++; *data=written^mismatch; return read_result;
}
int main(void)
{
    unsigned on, method, mode;
    gl_control_t c;
    I2C_HandleTypeDef hal={0}; fpga_i2c_t dev;
    fpga_i2c_init(&dev,&hal,0x36);
    for(on=0;on<256;on++) for(method=0;method<256;method++)
        assert(gl_control_encode((uint8_t)on,(uint8_t)method)==((on==1 && method==1)?0xa1:0xa0));
    for(mode=0;mode<256;mode++)
        assert(gl_mode_uses_vsync((uint8_t)mode)==(mode==1 || mode==2 || mode==0x14 || mode==0x15));
    gl_control_init(&c); assert(c.pending && c.desired==0xa0);
    write_result=HAL_TIMEOUT; gl_control_service(&c,&dev,0xfffffff0u);
    assert(writes==1 && reads==0 && c.pending && c.last_result==HAL_TIMEOUT);
    gl_control_service(&c,&dev,0x53u); assert(writes==1); // 99 ms across wrap
    write_result=HAL_OK; read_result=HAL_BUSY;
    gl_control_service(&c,&dev,0x54u); assert(writes==2 && reads==1 && c.pending);
    read_result=HAL_OK; mismatch=1;
    gl_control_service(&c,&dev,0xb8u); assert(writes==3 && reads==2 && c.pending && c.last_result==HAL_ERROR);
    mismatch=0; gl_control_service(&c,&dev,0x11cu);
    assert(!c.pending && writes==4 && written==0xa0);
    gl_control_service(&c,&dev,0x503u); assert(writes==4); // 999 ms refresh
    gl_control_service(&c,&dev,0x504u); assert(writes==5 && !c.pending);
    gl_control_set_ui(&c,1,1); write_result=HAL_ERROR;
    gl_control_service(&c,&dev,0x505u); assert(c.pending && written==0xa1 && writes==6);
    gl_control_set_ui(&c,2,1); write_result=HAL_OK;
    gl_control_service(&c,&dev,0x506u); assert(!c.pending && written==0xa0 && writes==7);
    gl_control_set_ui(&c,1,2); gl_control_service(&c,&dev,0x507u); assert(writes==7);
    gl_control_set_ui(&c,1,1); gl_control_service(&c,&dev,0x508u); assert(written==0xa1 && writes==8);
    gl_control_set_ui(&c,255,1); gl_control_service(&c,&dev,0x509u); assert(written==0xa0 && writes==9);
    puts("PASS GL control: 65536 UI pairs, 256 modes, transport failures/retry/refresh/tick wrap/Off supersession");
    return 0;
}
