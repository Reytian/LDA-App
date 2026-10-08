# LDA V4 model license

Copyright (c) 2026 Haotian Yi. All rights reserved.

"LDA V4" is the detection model that comes with LDA (Legal Document
Anonymizer): the Core ML model, its runtime settings and its tokenizer files,
as shipped in `LDA.app/Contents/Resources/LDA-V4`, and the same files in any
other form.

LDA V4 is privately owned. It is not part of LDA's source code and is not
licensed under the GNU General Public License that covers LDA.

1. **Use within LDA.** You may use LDA V4 free of charge as part of LDA.
2. **Sharing LDA.** You may redistribute copies of LDA that include LDA V4
   unmodified, as a whole.
3. **Everything else needs permission.** Any other use requires prior written
   permission from the copyright holder. This includes:
   - using LDA V4 outside LDA;
   - copying, extracting or redistributing it apart from LDA;
   - modifying or fine-tuning it;
   - using it to train or derive other models.
4. **No warranty.** LDA V4 is provided "as is", without warranty of any kind,
   express or implied. To the extent permitted by law, the copyright holder is
   not liable for any damages arising from its use.

Permission requests: formelocale@protonmail.com.

## Third-party notices

LDA V4 is fine-tuned from `microsoft/Multilingual-MiniLM-L12-H384`, used under
the MIT License:

```
MIT License

Copyright (c) Microsoft Corporation.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Its training data was derived from public legal texts, with real personal data
replaced by synthetic values before storage. No source text is distributed with
the model. Sources and their licenses:
- KL3M edgar-agreements (ALEA Institute), via laion/edgar_agreements: CC BY;
- ACORD (The Atticus Project), LexGLUE LEDGAR and Common Paper standard
  agreements: CC BY 4.0;
- LeCaRDv2: MIT;
- SAMR 合同示范文本库 (国家市场监督管理总局): public model contracts;
- SPC/SPP guiding cases, CourtListener opinions, PRC and HK statutes: public
  legal texts;
- MNBVC law/judgement sample (liwu/MNBVC): tagged MIT.
