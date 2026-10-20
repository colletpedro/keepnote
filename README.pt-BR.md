<p align="right"><a href="README.md">English</a></p>

![KeepNote — notas adesivas na borda da tela](docs/cover.png)

<p align="center"><a href="https://colletpedro.github.io/keepnote/pt-br/"><img src="docs/media/keepnote-preview.gif" alt="Prévia do vídeo do KeepNote" width="640"><br>Assista ao vídeo completo</a></p>

# KeepNote

Notas adesivas para macOS que ficam esperando como uma fileira de abas coloridas na borda direita da tela: leve o cursor até lá, escolha uma nota, escreva, e ela volta a sair do caminho.

**[Baixar KeepNote.dmg](https://github.com/colletpedro/keepnote/releases/latest/download/KeepNote.dmg)**

Requer um Mac com chip Apple (M1 ou mais novo) e macOS 13 ou mais recente. O download é feito só para chips Apple.

## Instalação

**1. Abra o download e arraste o KeepNote para Aplicativos.**

**2. Abra o KeepNote em Aplicativos.** O macOS vai avisar que não foi possível verificar o app. Clique em **OK** (ou **Concluído**). É esperado; [o motivo está abaixo](#por-que-o-macos-mostra-um-aviso).

**3. Permita uma vez.** Abra **Ajustes do Sistema → Privacidade e Segurança**, role até **Segurança**, clique em **Abrir Mesmo Assim** ao lado do KeepNote e confirme. O macOS não pergunta de novo para esta cópia do app. (No macOS 13 e 14 também dá para clicar no app com a tecla Control e escolher **Abrir**.)

## Atualizações

O KeepNote não verifica atualizações sozinho, porque não tem acesso à rede. As versões novas saem [no site](https://colletpedro.github.io/keepnote/pt-br/) e na [página de releases](https://github.com/colletpedro/keepnote/releases). **Ajustes → Sobre → Buscar atualizações…** abre o site no navegador.

## Por que o macOS mostra um aviso?

O KeepNote não é notarizado pela Apple. A notarização exige uma assinatura paga do Apple Developer (US$ 99 por ano), e o KeepNote é um projeto gratuito e de código aberto, então por enquanto ele é distribuído sem ela. O macOS mostra esse aviso para todo app que não passou por esse processo. Ele diz que a Apple não verificou o app, não que há algo errado com ele. Estas são as quatro coisas que você mesmo pode conferir:

1. **Dá para ler e compilar.** Todo o código-fonte está neste repositório, sem bibliotecas de terceiros. `./Scripts/build.sh` compila o mesmo app a partir dele.
2. **Ele não consegue usar a rede.** O KeepNote roda no sandbox do macOS sem os entitlements de rede, então o sistema recusa qualquer conexão que ele tentasse fazer. Confira: `codesign -d --entitlements - /Applications/KeepNote.app` não lista acesso à rede.
3. **Ele só alcança o que você der.** Fora do próprio contêiner, o sandbox deixa o KeepNote abrir apenas as pastas e os arquivos que você escolher, para sync, importação e exportação. O texto das suas notas é cifrado no disco com uma chave que fica no Keychain deste Mac.
4. **Dá para conferir o download.** Cada versão traz um arquivo `KeepNote.dmg.sha256`. `shasum -a 256 KeepNote.dmg` deve imprimir o mesmo valor.

## O que ele faz

- **Uma pilha na borda da tela.** As notas são abas na borda direita, ou na esquerda (Ajustes → Pilha → Borda da tela): a pilha inteira, as espiadas e as notas ancoradas se espelham para sair em direção ao meio da tela, e um Dock de qualquer lado fica livre. Passar o cursor pela borda abre as abas em leque, cada uma com sua cor e seu rótulo; a pilha rola quando há muitas. Tocar numa aba mostra uma espiada da nota sem tirar o foco do app em que você está; clicar abre a nota para edição.
- **Ancorada ou solta.** Uma nota aberta fica ancorada à pilha e fecha quando você clica em outro lugar. **Flutuar nota** (⌥⌘P) a descola da borda para ela ficar na tela, redimensionável, e lembra a posição; arrastar uma nota flutuante de volta até a borda da pilha a devolve (**Voltar à pilha**).
- **Markdown enquanto você escreve.** Negrito, itálico, tachado, destaque, links, títulos, listas com marcador, numeradas e checklists (com recuo e renumeração automática), citações, código, tabelas e divisores, tudo com atalho e no menu Ferramentas dentro da nota.
- **Cores e tags.** Cinco cores de papel, trocáveis a qualquer momento, e `#tags` com sugestões enquanto você digita. A janela Todas as notas filtra por tag e busca no título, nas tags e no texto.
- **Notas daily.** Dê a uma nota a tag `daily`, ou use **Daily de hoje** (⌥⌘Y, ou o botão de calendário na pilha). A pilha mantém as dailies dos seus dois dias mais recentes; as mais antigas são arquivadas e ficam em **Daily**, em Todas as notas, agrupadas por dia. Você pode definir um modelo para as novas notas daily (Ajustes → Daily → **Editar modelo da Daily…**).
- **Fixar, manter e arquivar por tempo.** *Fixar no centro* prende até cinco notas no meio da pilha, sempre inteiras. *Manter na pilha* livra uma nota do arquivamento. Notas que você não abre há 7, 14 ou 30 dias (você escolhe em Ajustes → Pilha → **Arquivar notas não abertas há**; 14 por padrão) vão sozinhas para Arquivadas, nunca são apagadas; nos dois últimos dias aparece um relógio na aba. Fixar, manter e as regras de arquivamento não mudam a data *Editada* da nota, que só muda quando você altera o texto ou o título.
- **Arquivadas e desfazer.** As notas arquivadas têm janela própria. Apagar uma nota dá 10 segundos (ajustável em Ajustes → Notas → **Desfazer uma exclusão por**) para desfazer.
- **Sincronização por pasta.** Opcionalmente (Ajustes → Sincronização), o KeepNote grava um arquivo de texto `.hmnote` por nota numa pasta que você escolhe (o iCloud Drive é sugerido). O provedor da pasta leva os arquivos entre os Macs; o KeepNote não tem servidor próprio.
- **Importar e exportar.** Exporte as notas em Markdown ou texto simples, um arquivo por nota ou um só documento, ou num arquivo KeepNote (`.hmnotearchive`) que preserva cores, estados e datas. A importação lê esse arquivo ou uma pasta de arquivos `.hmnote`.
- **Onde ele fica.** Na barra de menus, e no Dock só enquanto uma das janelas dele está aberta. **Abrir ao iniciar sessão** e **Mostrar sobre apps em tela cheia** (Ajustes → Geral) são opcionais. O idioma do app se escolhe em Ajustes → Geral → **Idioma**.

## Compilar a partir do código

Basta o Command Line Tools da Apple (`xcode-select --install`) ou o Xcode. O KeepNote não tem dependências além dos frameworks do sistema.

```bash
git clone https://github.com/colletpedro/keepnote.git
cd keepnote
./Scripts/build.sh --run
```

Isso compila o app em `build/` e o abre. Num clone novo não há certificado de assinatura, então o build é assinado **ad-hoc** e mostra um aviso visível. A assinatura ad-hoc muda a cada build, então depois de cada recompilação o macOS volta a pedir acesso ao item do Keychain com a chave que cifra as notas; escolha Permitir, nenhuma nota se perde.

Para acabar com esses pedidos, crie um certificado de assinatura uma vez: em Acesso às Chaves, **Assistente de Certificado → Criar um Certificado…**, nome **KeepNote Dev**, tipo de identidade **Raiz Autoassinada**, tipo de certificado **Assinatura de Código**. O build passa a usá-lo sozinho. Outro certificado funciona com `KEEPNOTE_SIGN_ID="Nome"`.

| Comando | O que faz |
|---|---|
| `./Scripts/build.sh` | build de debug em `build/` |
| `./Scripts/build.sh --release` | build otimizado |
| `./Scripts/build.sh --install` | build de release, substitui `/Applications/KeepNote.app` (recusa um build ad-hoc, a menos que `KEEPNOTE_ALLOW_ADHOC=1`) |
| `./Scripts/release.sh` | release arm64 assinado com `KEEPNOTE_SIGN_ID`, empacotado em `dist/KeepNote.dmg` com o `.sha256` |
| `./Scripts/test.sh` | as suítes de teste; usam bancos temporários e nunca tocam nas suas notas |

`KEEPNOTE_SDK=/caminho/para/MacOSX.sdk` substitui o SDK que o build escolhe.

## Atalhos

Estes são os padrões. Todos os atalhos abaixo, menos Fechar, podem ser trocados em Ajustes → Atalhos: clique no atalho e pressione a nova combinação, que precisa de ⌘, ⌥ ou ⌃. Esc cancela, Delete deixa o comando sem atalho, e **Restaurar padrões** traz estes de volta. Uma combinação que outro comando do KeepNote já usa, ou que o sistema recusa porque outro app a tem, não é aceita; o campo diz o motivo. Seus atalhos ficam guardados neste Mac, e os menus, as dicas e a janela de boas-vindas mostram sempre os atuais. Os atalhos de formatação são fixos.

| Globais, de qualquer app | O que faz |
|---|---|
| `⌥⌘N` | Nova nota |
| `⌥⌘A` | Todas as notas |
| `⌥⌘E` | Arquivadas |
| `⌥⌘Y` | Daily de hoje |

| Numa nota | O que faz |
|---|---|
| `esc` / `⌘W` | Fechar |
| `⌘F` | Buscar na nota |
| `⌘G` / `⇧⌘G` | Próxima / anterior ocorrência |
| `⌥⌘C` / `⇧⌥⌘C` | Próxima / anterior cor |
| `⌥⌘P` | Flutuar nota / Voltar à pilha |
| `⇧⌘E` | Arquivar / trazer de volta |
| `⇧⌘⌫` | Apagar (com desfazer) |
| `⇥` / `⇧⇥` | Recuar / voltar um nível num item de lista |

| Formatação | O que faz |
|---|---|
| `⌘B` `⌘I` `⇧⌘X` | Negrito, itálico, tachado |
| `⇧⌘H` | Destaque |
| `⌘E` | Código em linha |
| `⌘K` | Link |
| `⌥⌘1` `⌥⌘2` `⌥⌘3` | Título 1, 2, 3 |
| `⇧⌘7` `⇧⌘9` `⇧⌘L` | Lista com marcador, lista numerada, checklist |
| `⇧⌘B` | Citação |
| `⌥⌘K` | Bloco de código |
| `⌥⌘T` `⌥⌘R` | Tabela, divisor |
| `⇧⌘D` | Data de hoje |

## Privacidade

O KeepNote não faz nenhuma conexão de rede. Não tem servidor, conta, telemetria nem analytics, e os entitlements dele (`Resources/KeepNote.entitlements`) são o sandbox, as pastas que você escolhe e os bookmarks delas, nada mais. Um link dentro de uma nota abre no seu navegador.

O texto das suas notas é cifrado no banco local (AES-GCM) com uma chave guardada no Keychain deste Mac, que nunca sai dele e não é sincronizada. Títulos e tags ficam sem cifra no banco para poderem ser buscados; os arquivos `.hmnote` do sync são texto simples, então continuam legíveis sem o app e ficam protegidos pelo que protege a pasta.

O banco fica em `~/Library/Containers/com.keepnote.KeepNote/Data/Library/Application Support/KeepNote/notes.sqlite`.

## Desinstalar

Primeiro saia do KeepNote (ícone da barra de menus → Encerrar KeepNote). Se **Abrir ao iniciar sessão** estiver ligado, desligue em Ajustes → Geral antes de apagar o app. Depois remova cada item:

| O quê | Onde | Como remover |
|---|---|---|
| O app | `/Applications/KeepNote.app` | Mova para o Lixo. |
| Banco (suas notas) | `~/Library/Containers/com.keepnote.KeepNote/Data/Library/Application Support/KeepNote/notes.sqlite`, com `notes.sqlite-wal` e `notes.sqlite-shm` ao lado | Apague o container inteiro, `~/Library/Containers/com.keepnote.KeepNote`. No Finder: Ir → Ir para a Pasta…, digite `~/Library/Containers` e mova a pasta chamada **KeepNote** para o Lixo. |
| Preferências | `~/Library/Containers/com.keepnote.KeepNote/Data/Library/Preferences/com.keepnote.KeepNote.plist` | Vai junto com o container acima. |
| Chave de criptografia | Keychain de login, item de senha com serviço `com.keepnote.KeepNote.bodykey`, conta `default` | Acesso às Chaves: busque `com.keepnote.KeepNote.bodykey` e apague. Ou no Terminal: `security delete-generic-password -s com.keepnote.KeepNote.bodykey` |
| Item de login | O próprio KeepNote, registrado no macOS (`SMAppService`) quando Abrir ao iniciar sessão está ligado | Desligue Abrir ao iniciar sessão antes de apagar o app. Se o app já foi apagado: Ajustes do Sistema → Geral → Itens de Início (Itens de Início e Extensões no macOS 15 em diante), selecione KeepNote em Abrir ao Iniciar Sessão e clique em −. |

A chave só serve para abrir aquele banco; remova os dois juntos. Sem o container, suas notas vão embora com ele, então exporte antes (Ajustes → Sobre → Exportar todas as notas…) se quiser guardá-las.

**A pasta de sync é sua.** O KeepNote nunca a apaga, e desinstalar deixa a pasta e os arquivos `.hmnote` e `.hmtemplate` exatamente onde estão. Apague você mesmo se não quiser mais.

## Licença

MIT. Veja [LICENSE](LICENSE).
