# Builds words.txt : common English words, most frequent first, lowercase a-z only, 2+ letters, no profanity
import re
from wordfreq import top_n_list
from better_profanity import profanity
profanity.load_censor_words()
out = []
for w in top_n_list('en', 24000):
    if re.fullmatch(r'[a-z]{2,}', w) and not profanity.contains_profanity(w):
        out.append(w)
out = out[:20000]
open('words.txt', 'w').write('\n'.join(out) + '\n')
print(len(out), out[:12])
