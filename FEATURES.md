# Phantom — mapa de features

O que já funciona, o que funciona com limite, e o que a gente ainda quer ter.

**Estado deste documento:** `0.8.0-dev`, branch `feat/branch-review` (PR #15). Último release
publicado: **v0.7.0**, em 19/08/2026. O fork divergiu do Ghostty em **05/08/2026**, com o
primeiro commit da sidebar — então tudo que está marcado como *nosso* abaixo foi construído
em pouco mais de duas semanas.

## Como ler as marcas

| marca | significado |
|---|---|
| ✅ | funcionando e visto na tela |
| ⚠️ | implementado e coberto por teste, **nunca aberto numa janela** |
| 🔶 | funciona, com um limite declarado — o limite está escrito ao lado |
| — | não começou |

A distinção entre ✅ e ⚠️ é a única que importa numa lista dessas: teste verde prova que a
decisão está certa, não que a coisa aparece na tela. Onde a verificação foi parcial, está dito
qual metade foi verificada.

## O que é nosso e o que vem do Ghostty

O terminal em si — emulação, render, splits, quick terminal, command palette, AppleScript,
App Intents, atualização por Sparkle — é do Ghostty, e é a razão de ser um fork e não um app
novo. O que o Phantom acrescenta é a camada de trabalho em volta dele:

| camada | origem |
|---|---|
| Terminal, splits, tema, fonte, quick terminal, command palette | Ghostty upstream |
| AppleScript, App Intents, secure input, confirmação de clipboard | Ghostty upstream |
| **Sidebar** (terminais, arquivos, git) | Phantom · 05/08 |
| **Editor de código dentro do pane** | Phantom · 09/08 |
| **LSP, autocomplete, hover, format** | Phantom · 12/08 |
| **Integração com agentes de IA** | Phantom |
| **Settings de LSP, Completion, Files, Ícones, Atalhos** | Phantom · 09–15/08 |

---

# Funcionando hoje

## Editor de código

Abre no mesmo pane do terminal, não numa janela separada — a ideia inteira do app é não trocar
de contexto para ler um arquivo.

| | feature | nota |
|---|---|---|
| ✅ | Quatro modos de apresentação | `source`, `preview` (Markdown), `diff` (git) e `split` |
| ✅ | Realce de sintaxe em 19 linguagens | JS/TS, Vue, Swift, Kotlin, Rust, Go, Python, Ruby, shell, JSON, YAML, Markdown, HTML, CSS, SQL, Zig, C, PHP, Terraform |
| ✅ | JSX realçado dentro de HTML e de SFC Vue | container de markup + regra própria; cache de regiões de SFC (1977 → 671 µs por tecla) |
| ✅ | Minimapa, gutter, banda da linha atual | |
| ✅ | Par de brackets sob o cursor + coloração por profundidade | varredura limitada a 4096 caracteres |
| ✅ | Auto-fechamento de brackets, aspas e **tags** | por linguagem: `&'a` em Rust não vira aspas; `.ts` nunca fecha tag, porque lá `<` só pode ser genérico |
| ✅ | ⌘Z / ⌘⇧Z | |
| ✅ | Menu de contexto montado a partir dos comandos disponíveis | |
| ✅ | Preview de Markdown com scroll e sync com o raw no split | |
| ✅ | Busca global por texto no workspace | ripgrep, com fallback para grep |
| ✅ | Formatar documento (⌘⇧F) e format-on-save | Prettier do projeto quando existe, LSP como fallback; falha do Prettier **não** cai para o LSP silenciosamente |
| ✅ | Prettier lendo a config do projeto | `.prettierrc` e 17 outros nomes; binário local antes do PATH; um arquivo ignorado é deixado em paz |
| ✅ | Snippets de Markdown pelo gatilho `/` | suprimido dentro de cerca de código; ligável/desligável em Settings |
| 🔶 | Render de Markdown no hint de símbolos | exemplo de código ainda sai em fonte de prosa |

## LSP e autocomplete

| | feature | nota |
|---|---|---|
| ✅ | 21 binários de servidor registrados | TS (o wrapper **e** o nativo `tsc --lsp`), Vue, Swift, Kotlin, Rust, Go, Zig, Python, Ruby, PHP, Java, C/C++, Bash, HTML, CSS/SCSS/LESS, JSON, YAML, Terraform, Markdown, Tailwind |
| ✅ | Mais de um servidor por arquivo | um `.vue` usa o servidor do Vue **e** o do TypeScript; hover, definition, references e rename perguntam a cada um até alguém responder |
| ✅ | Escolha de toolchain por projeto | projeto com `tsserver.js` recebe o wrapper; projeto sem ele recebe o binário nativo — TypeScript 7 não tem `tsserver.js` |
| ✅ | Lista de sugestões com ícone, tipo e painel de documentação | abre em 1 caractere, como no VS Code |
| ✅ | Instalar e desinstalar servidor pelo Settings | com hint de instalação por servidor e link para a doc oficial |
| ✅ | Diagnósticos, hover, ir para definição, referências, rename | |
| ⚠️ | **Autocomplete de Tailwind dentro de `className=""`** | o roteamento foi verificado na tela (o app sobe o servidor); **a lista aparecendo não foi** |
| 🔶 | Autocomplete de CSS em JSX | `style={{ }}` funciona (857 propriedades). Template literal (`styled.div`) não — precisaria de documento virtual + servidor de CSS |

### Sobre o Tailwind, com número

O servidor oficial (`@tailwindcss/language-server`) devolve **o universo inteiro** a cada
consulta e espera que o cliente filtre: 11.534 itens, 2,5 MB de JSON, 30–60 ms. Dentro do
atributo de classe, cada tecla ranqueia isso em ~27 ms no main actor. **Fora** do atributo ele
responde 0 itens em 0,4 ms, então nada disso pesa em código comum.

## Git

| | feature | nota |
|---|---|---|
| ✅ | Painel com status do repositório | staged, não-staged, untracked, conflito |
| ✅ | Diff no estilo do VS Code, split H e V | |
| ✅ | **Branch review** — o que a branch põe num PR | commits + arquivos contra a base, antes de abrir o PR; clique abre o diff contra a base |
| ✅ | Menu de contexto completo no arquivo | 4 grupos de ações |
| ✅ | `Add to .gitignore` também em arquivo já rastreado | paridade com o comportamento do VS Code |
| ✅ | Atualiza ao salvar, nos dois sentidos | introduzir mudança e remover mudança |
| ✅ | Ícone do diff no seletor de apresentação | `text.append` |

## Explorador de arquivos

| | feature | nota |
|---|---|---|
| ✅ | Árvore com watcher de diretório | |
| ✅ | Temas de ícone de arquivo, carregados de disco | parser tolerante — são arquivos de terceiro |
| ✅ | Um destaque só: o arquivo da aba em foco | seleção virou contorno, porque Return/Delete/novo-arquivo dependem dela |
| ✅ | Scroll mínimo ao clicar, sem recentralizar | |
| ✅ | Ao limpar a busca, a árvore vai para o arquivo aberto | expande os ancestrais |
| ✅ | Atalhos remapeáveis, **mais de um por comando** | com migração das chaves antigas |
| 🔶 | Workspace na raiz do disco | `isInsideRoot` falha com raiz `/` |

## Agentes de IA

A parte que não existe em nenhum outro terminal, e a razão do fork.

| | feature | nota |
|---|---|---|
| ✅ | Iniciar Claude, Codex ou OpenCode na sidebar, no grupo **e** na aba | ações no hover da linha; escondidas quando já há sessão viva |
| ✅ | Instalar os hooks dos três pelo Settings | |
| ✅ | Restaurar a conversa ao reabrir a aba | decisão vem do arquivo de estado da aba, não de heurística |
| ✅ | Sessão encerrada **não** é retomada no próximo launch | `end=user` só é marcado quando um app vivo e não-saindo testemunhou o fim |
| ✅ | Tag de plano do Claude na aba, só com sessão viva | plano casado por diretório de projeto |
| ✅ | Estado do agente na aba (rodando, idle, erro) | reportado pelos hooks |
| ✅ | Ícones de Claude/Codex/OpenCode no customizador de ícone | seção "AI Agents/Harness", com color picker |
| ✅ | Processos são encerrados ao fechar aba ou janela | medido com controle: 3 sobreviventes sem o fix, 0 com |
| 🔶 | Fim de sessão do OpenCode | ele não emite evento de fim; `idle` é fim de turno. Precisaria de sinal de processo |

## Terminal, abas e janela

| | feature | nota |
|---|---|---|
| ✅ | Grupos de abas definidos pelo usuário | com ícone e cor por grupo |
| ✅ | Sessão do terminal salva e restaurada | |
| ✅ | Porta do dev server detectada e mostrada na aba | por socket em escuta, não por banner — funciona igual em node, go, java ou `python -m http.server` |
| ✅ | Sem piscada ao reiniciar o terminal | a cor é aplicada antes do primeiro frame |
| 🔶 | Tab bar em fullscreen | sobreposição conhecida |

## Settings

Nove seções: General, Appearance, Icon, Sidebar, Files, Behaviors, Keyboard Shortcuts,
Language Servers e Agents. Atalhos aceitam **mais de uma combinação por comando** e avisam de
colisão. As preferências de GUI ficam em `UserDefaults` e não no arquivo de config do Ghostty —
chave desconhecida lá faz o core abrir popup de erro.

---

# Não verificado na tela

Não é uma lista de bugs — é uma lista de coisas que passam nos testes e nunca foram olhadas
numa janela. Cada linha aqui é um pedido de cinco minutos de uso, não de trabalho.

| item | o que falta olhar |
|---|---|
| Lista de sugestões do Tailwind | digitar `w-` dentro de `className=""` e ver `w-full` na lista |
| Sync de scroll no preview de Markdown splitado | o mapa por linha existe; nunca foi aberto |
| Busca de arquivo por tab e path | testado na parte pura; teclado sintético não alcança os campos |
| Branch review | a seção monta e o clique abre o diff em teste; a tela não foi olhada |

---

# O que queremos ter

## Edição — o que mais falta no dia a dia

| porte | item | nota |
|---|---|---|
| médio-alto | **Mover linha (⇧⌥) e multi-cursor** | nada disso existe hoje. É o buraco mais sentido em relação a um editor de verdade |
| médio | Autocomplete de CSS em template literal | `styled.div` e afins; precisa de documento virtual + servidor de CSS. Medido: não é pequeno |
| médio | Visualizador de imagem | |
| médio | Visualizador de PDF | PDFKit dá conta |
| médio | Visualizador de CSV | dados + preview, no molde do Markdown |
| — | ~~Visualizador de XLSX~~ | **sugestão de corte**: exigiria parser de planilha |

## Git

| porte | item | nota |
|---|---|---|
| médio | Busca dentro do painel de Git | |
| grande | **Módulo de Worktrees** | hoje só existe a intenção — `SidebarPane` diz "planned next" |

## Agentes

| porte | item | nota |
|---|---|---|
| grande | **Seguir o agente enquanto ele altera arquivos** | precisa de recorte antes de estimativa: rolar até a mudança? diff ao vivo? abrir o arquivo tocado? |

## Performance — os dois com número medido

| porte | item | ganho |
|---|---|---|
| médio | Respeitar `isIncomplete` e refiltrar local | hoje é parseado e ninguém age sobre ele. Tiraria o round-trip e o parse de 2,5 MB de **toda tecla depois da primeira** dentro de um atributo de classe |
| médio | Tirar o `rank` do main actor | os 27 ms por tecla saem da thread que desenha. Exige ler a query, ranquear e reconferir que o caret não andou |

## Decisões de produto, não implementação

| item | a decisão em aberto |
|---|---|
| Indicador de cor do terminal | barrinha vertical vs pintar a aba — a preferência é pintar; o problema é o estado selecionado |
| Ícone de listagem de planos no grupo | receio de poluir o header |

---

# Dívidas conhecidas no código

Achadas durante o trabalho, anotadas em vez de corrigidas no meio de outra frente. Nenhuma
quebra o uso hoje; todas são o tipo de coisa que custa caro quando alguém tropeça sem saber.

| item | efeito |
|---|---|
| `CodeTextStorage.highlight` apaga os sublinhados de diagnóstico | você edita uma linha com erro e o sublinhado desaparece até os diagnósticos mudarem |
| Nada poda `~/.cache/phantom/tab-states/` | registro antigo continua retomável para sempre |
| `.svelte` sem formatação | o Prettier de núcleo não tem parser; exigiria ler a config para saber do plugin |
| `ShellCommand` não faz stdin | por isso o `PrettierRunner` duplica ~70 linhas de plumbing de processo |
| `CompletionSession` virou write-only | funciona como flag de "lista aberta"; o painel é dono do resto |
| Bounds de `additionalEdits` testa `location` e não `NSMaxRange` | inalcançável hoje, mas lê como se cobrisse mais do que cobre |
| `insertReplace` decidido no insert range para o app inteiro | equivale ao `editor.suggest.insertMode` do VS Code; virar preferência é outra decisão |
| `reportEmpty` explica lista vazia pelas capacidades do servidor primário | com dois servidores no arquivo, a explicação pode ser do servidor errado |
| Fan-out de completion é sequencial | o comentário dizia "revisitar se um terceiro servidor entrar numa linguagem". Entrou (Tailwind). Fica barato só porque ele responde vazio em 0,4 ms fora do atributo |

## Armadilhas de build que valem estar escritas

| armadilha | o que fazer |
|---|---|
| `xcodebuild` compila **só** o Swift | o core Zig chega como `macos/GhosttyKit.xcframework`, gitignorado. Sem `zig build`, você testa Swift novo contra core velho |
| Detrito de codesign (`Icon\r` + FinderInfo) reaparece a cada build | limpar **antes de cada** `xcodebuild`, ou o `CodeSign` falha com "resource fork … not allowed" |
| Estado do app vive em **dois** bundle ids | `com.ipetinate.phantom*` e `com.mitchellh.ghostty`. Quem limpa estado precisa dos dois |
| `log show` não captura nada do app | rodar o binário com `GHOSTTY_LOG=stderr,macos` |
| Bumpar `build.zig.zon` **antes** do merge | o release dispara no push para `main`; tag duplicada falha em silêncio |
| Teste de tempo afirma **razão**, não constante | orçamento em milissegundos reprova no runner compartilhado do CI — já aconteceu |
