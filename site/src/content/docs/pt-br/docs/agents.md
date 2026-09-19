---
title: Agentes
description: Os seis agentes de código que o Phantom conhece, o estado que ele mostra na aba, o resume de sessão e a instalação de hooks com um clique.
sidebar:
  label: Agentes
---

O Phantom é construído em torno de rodar vários agentes de código ao mesmo
tempo. Ele conhece seis deles e trata a sessão de um agente como algo que a aba
*tem*, não como algo que você precisa lembrar.

## Agentes suportados

Claude Code, Codex, OpenCode, Antigravity, Kimi Code e Pi.

Cada um tem uma marca própria na sidebar, uma entrada no menu de novo terminal
e um instalador para o formato de configuração dele — JSON na maioria, TOML no
Codex.

## Iniciar uma sessão

Pelo cabeçalho de um grupo ou pelo menu de novo terminal, escolha um agente. O
Phantom abre uma aba no diretório certo com o agente já rodando. Um grupo de
projeto inicia na raiz do projeto; uma worktree inicia naquele checkout.

## O estado na aba

Uma linha mostra se a sessão está **trabalhando**, **esperando por você** ou
**concluída**. É essa a razão de a sidebar existir: uma dúzia de agentes em uma
dúzia de repositórios é, de outra forma, uma dúzia de abas idênticas.

O estado vem de hooks que o agente executa. Instale-os em
**Configurações › Agents** com um clique — o Phantom escreve um script no
diretório de hooks do próprio agente e o registra. O nome do script carrega o
nome do build, então um build de desenvolvimento não sobrescreve o que a sua
cópia instalada usa.

No Claude Code a aba também mostra o plano atual, quando existe um.

## Todas as sessões numa tela

**Window › Agents**, ou ⇧⌘A, abre uma janela listando todas as sessões de
agente do app — todas as janelas, todos os splits, agrupadas por projeto. O que
precisa de você sobe: esperando e falhou primeiro, depois o que está rodando, e
dentro de cada faixa o mais antigo na frente, então a sessão parada há mais
tempo é a que você vê.

Cada card traz o agente, o estado, há quanto tempo está nele, o projeto e o
branch, e as últimas linhas que o agente escreveu. Três ações:

- **Open** traz aquele terminal para a frente — a janela certa, a aba certa, o
  split certo. Uma janela em outra Space fica onde você deixou.
- **Interrupt** manda Ctrl-C.
- O campo de texto responde o agente: o que você digitar vai seguido de Return.

Responder é texto livre de propósito. O Phantom sabe que um agente está
esperando, mas não o que ele está perguntando — o estado que chega é uma
palavra só, sem a pergunta junto. Então a tela digita o que você mandar e nunca
adivinha. Para um menu de setas, abra o terminal e responda lá.

Uma sessão aparece quando os hooks do agente estão instalados; **Settings ›
Agents** instala.

Um card dizendo que o processo sumiu é um agente que morreu sem escrever a
última palavra. O Phantom confere o processo em primeiro plano do terminal
enquanto esta janela está aberta, e essa conferência só pode retirar uma
afirmação, nunca criar uma.

## Resume

Fechar uma aba mata os processos dentro dela, agente incluído. Reabrir a aba —
restaurando a sessão ou pelo menu da própria aba — inicia o agente de novo com
`--resume` contra a conversa que ele tinha, então a sessão continua em vez de
recomeçar.

Desligue isso em **Restore agent sessions**, nas Configurações.

## Deixar um agente dirigir o Phantom

Um agente também pode agir sobre a janela em que está rodando: abrir um arquivo
numa linha, ler a saída de outro terminal, criar uma worktree. Isso é o servidor
MCP, documentado em [O servidor MCP](/pt-br/docs/mcp/).
