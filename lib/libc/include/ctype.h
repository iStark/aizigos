/* ctype.h — character classes, ASCII only.
 *
 * A byte above 0x7F is part of a UTF-8 sequence here, not a letter with an
 * accent: nothing in this system uses a locale, and pretending otherwise
 * would be the start of a long lie.
 */
#ifndef AIZIGOS_CTYPE_H
#define AIZIGOS_CTYPE_H

int isalpha(int c);
int isdigit(int c);
int isalnum(int c);
int isspace(int c);
int isupper(int c);
int islower(int c);
int isxdigit(int c);
int ispunct(int c);
int isprint(int c);
int iscntrl(int c);
int toupper(int c);
int tolower(int c);

#endif
