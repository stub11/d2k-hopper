#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <arpa/inet.h>
#include "ipv6.h"

static size_t build(uint8_t *b, size_t cap, int hopopt) {
    assert(cap >= 128);
    memset(b, 0, cap);
    b[0]=0x60; b[7]=64;
    b[8]=0x20; b[9]=0x01; b[10]=0x0d; b[11]=0xb8; b[23]=1;
    b[24]=0x20; b[25]=0x01; b[26]=0x0d; b[27]=0xb8; b[39]=2;
    size_t off=40;
    if(hopopt){ b[6]=IPPROTO_HOPOPTS; b[40]=IPPROTO_TCP; b[41]=0; off+=8; }
    else b[6]=IPPROTO_TCP;
    b[off]=0xab; b[off+1]=0xcd; b[off+2]=1; b[off+3]=0xbb;
    b[off+12]=0x50; b[off+13]=0x02;
    size_t total=off+20;
    uint16_t plen=htons((uint16_t)(total-40)); memcpy(b+4,&plen,2);
    return total;
}

static void test_basic(void){uint8_t b[128];struct d2k_ip6_info i;size_t n=build(b,sizeof b,0);assert(d2k_parse_ipv6(b,n,&i)==D2K_IP6_TCP);assert(i.hop_limit==64);assert(i.payload_len==0);assert(i.tcph);puts("PASS basic TCP");}
static void test_ext(void){uint8_t b[128];struct d2k_ip6_info i;size_t n=build(b,sizeof b,1);assert(d2k_parse_ipv6(b,n,&i)==D2K_IP6_TCP);assert(i.tcph);puts("PASS hop-by-hop");}
static void test_bad(void){uint8_t b[128];struct d2k_ip6_info i;size_t n=build(b,sizeof b,0);assert(d2k_parse_ipv6(b,10,&i)==D2K_IP6_ERR);b[0]=0x40;assert(d2k_parse_ipv6(b,n,&i)==D2K_IP6_ERR);b[0]=0x60;uint16_t p=htons(1000);memcpy(b+4,&p,2);assert(d2k_parse_ipv6(b,n,&i)==D2K_IP6_ERR);puts("PASS malformed/truncated");}
static void test_checksum(void){struct in6_addr a,b;assert(inet_pton(AF_INET6,"2001:db8::1",&a)==1);assert(inet_pton(AF_INET6,"2001:db8::2",&b)==1);uint8_t tcp[20]={0};tcp[12]=0x50;tcp[13]=2;uint16_t c=d2k_tcp_checksum_ipv6(&a,&b,tcp,sizeof tcp);assert(c!=0);puts("PASS checksum");}
int main(void){test_basic();test_ext();test_bad();test_checksum();puts("IPv6 tests passed.");return 0;}
