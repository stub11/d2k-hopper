#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "d2k_tls.h"
#include "d2k_quic.h"

#define CHECK(x,msg) do { if (!(x)) { fprintf(stderr,"FAIL: %s\n",(msg)); return 1; } } while (0)

static const uint8_t HEX_TLS_VALID[]={
0x16,0x03,0x03,0x00,0x42,0x01,0x00,0x00,0x3e,0x03,0x03,
0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,
0x00,0x00,0x04,0x13,0x01,0x01,0x00,0x00,0x21,0x00,0x00,0x00,0x0f,0x00,0x0d,0x00,0x00,0x0a,
'e','x','a','m','p','l','e','.','c','o','m',0x00,0x2b,0x00,0x02,0x03,0x04};
static const uint8_t HEX_TLS_TRUNCATED[]={
0x16,0x03,0x03,0x00,0x42,0x01,0x00,0x00,0x3e,0x03,0x03,
0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,
0x00,0x00,0x04,0x13,0x01,0x01,0x00,0x00,0x21,0x00,0x00,0x00,0x0f,0x00,0x0d,0x00,0x00,0x0a,'e','x','a'};
static const uint8_t HEX_QUIC_VALID[]={
0xc0,0x00,0x00,0x00,0x01,0x08,1,2,3,4,5,6,7,8,0x04,9,10,11,12,
0x00,0x00,0x00,0x01,0x40,0x08,0,1,2,3,4,5,6,7,0x00,0x00};
static const uint8_t HEX_QUIC_TRUNCATED[]={
0xc0,0x00,0x00,0x00,0x01,0x08,1,2,3,4,5,6,7,8,0x04,9,10,11};

int main(void){
 d2k_tls_info t; d2k_quic_info q;
 CHECK(d2k_tls_parse(HEX_TLS_VALID,sizeof HEX_TLS_VALID,&t)==0,"TLS valid parse");
 CHECK(t.is_client_hello&&t.have_sni&&t.sni_len==11,"TLS ClientHello/SNI");
 CHECK(memcmp(HEX_TLS_VALID+t.sni_off,"example.com",11)==0,"TLS SNI value");
 printf("TLS_VALID: PASS SNI=example.com\n");
 CHECK(d2k_tls_parse(HEX_TLS_TRUNCATED,sizeof HEX_TLS_TRUNCATED,&t)==0&&!t.have_sni,"TLS truncated");
 printf("TLS_TRUNCATED: PASS rejected safely\n");
 CHECK(d2k_quic_parse(HEX_QUIC_VALID,sizeof HEX_QUIC_VALID,&q)==1,"QUIC valid parse");
 CHECK(q.is_initial&&q.version==1&&q.dcid_len==8&&q.scid_len==4,"QUIC Initial header");
 CHECK(q.dcid[0]==1&&q.dcid[7]==8&&q.scid[0]==9&&q.scid[3]==12,"QUIC DCID/SCID");
 printf("QUIC_VALID: PASS version=1 DCID=0102030405060708 SCID=090a0b0c\n");
 CHECK(d2k_quic_parse(HEX_QUIC_TRUNCATED,sizeof HEX_QUIC_TRUNCATED,&q)==0,"QUIC truncated");
 CHECK(d2k_quic_parse(HEX_QUIC_VALID,5,&q)==0,"QUIC short header");
 printf("QUIC_TRUNCATED: PASS rejected safely\nGATE4_RESULT=SUCCESS\n");
 return 0;
}
