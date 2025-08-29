#ifndef ubxmsgH
#define ubxmsgH
typedef unsigned long int TUbxKey;
extern TUbxKey ubx_find_cfg_byStr(const char *str);
// 0 - not found;
const char *ubx_find_cfg_byKey(TUbxKey key);
// NULL - not found;
extern bool ubx_is_cfg(const char *str);
extern int ubx_cfg_value_len(TUbxKey key);
const char *ubx_find_cmd_byKey(int key);
// NULL - not found;
extern TUbxKey ubx_find_cmd_byStr(const char *str);
// 0 - not found;
#endif // ubxmsgH

 