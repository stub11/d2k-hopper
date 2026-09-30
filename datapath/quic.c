#include <string.h>
#include "d2k_quic.h"
static int quic_varint(const uint8_t *b,size_t len,size_t *off,uint64_t *v){
 if(*off>=len)return 0; uint8_t x=b[*off]; size_t n=(size_t)1U<<(x>>6);
 if(n>len-*off)return 0; uint64_t z=x&0x3fU;
 for(size_t i=1;i<n;i++)z=(z<<8)|b[*off+i]; *off+=n; *v=z; return 1;
}
int d2k_quic_parse(const uint8_t *b,size_t len,d2k_quic_info *out){
 if(!out)return 0; memset(out,0,sizeof *out); if(!b||len<7)return 0;
 uint8_t h=b[0]; if(!(h&0x80U)||!(h&0x40U)||((h>>4)&3U)!=0)return 0;
 uint32_t v=((uint32_t)b[1]<<24)|((uint32_t)b[2]<<16)|((uint32_t)b[3]<<8)|b[4];
 if(v!=1U&&v!=0x6b333833U)return 0; size_t o=5; uint8_t dl=b[o++];
 if(dl>20||(size_t)dl>len-o)return 0; out->dcid_len=dl; memcpy(out->dcid,b+o,dl); o+=dl;
 if(o>=len)return 0; uint8_t sl=b[o++]; if(sl>20||(size_t)sl>len-o)return 0;
 out->scid_len=sl; memcpy(out->scid,b+o,sl); o+=sl;
 if(!quic_varint(b,len,&o,&out->token_len))return 0;
 if(out->token_len>(uint64_t)(len-o))return 0; o+=(size_t)out->token_len;
 if(!quic_varint(b,len,&o,&out->payload_len))return 0;
 if(out->payload_len>(uint64_t)(len-o))return 0; out->header_len=o; out->is_initial=1; return 1;
}
