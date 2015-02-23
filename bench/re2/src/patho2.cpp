#include "../common.hpp"

// RE2 program corresponding - approximately - to patho2.has
// output the string if it ends with a "b". 
string regex("(?:([a-z]*a)|([a-z]*b))?\n?");

#undef NCAP
#define NCAP 2

int main(int argc, char *argv[]) {
  // Pre-compile pattern
  uint64_t preCompile = getTimeMs();
  RE2 pattern(regex);

  // Initialize capture arguments
  RE2::Arg *args[NCAP];
  string target[NCAP];
  for (int i = 0; i < NCAP; i++) {
    args[i] = new RE2::Arg(&target[i]);
  }

  // START LINE-BASED TIMING
  uint64_t start = getTimeMs();
  uint64_t line = 0;
  // from man fgets:
  // "The newline, if any, is retained."
  while(fgets(buffer, LINE_LEN, stdin)) {
    line++;
    bool match = RE2::FullMatchN(buffer, pattern, args, NCAP);
    if(!match) {
      cerr << "match error on line " << line << endl;
      cerr << buffer;
      return 1;
    } else {
      cout << target[1] << endl;
    }
  }

  uint64_t stop = getTimeMs();
  // END LINE-BASED TIMING

  cerr << "matching was successful." << endl;
  cerr << "compilation (ms): " << start - preCompile << endl;
  cerr << "matching (ms):    " << stop - start << endl;
  
  return 0;
}
