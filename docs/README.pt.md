# Turbo Optimizer: otimizador, limpador e ferramenta de reparo gratuita para Windows 10/11

[English](../README.md) | [العربية](README.ar.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | **Português** | [Русский](README.ru.md) | [简体中文](README.zh.md) | [हिन्दी](README.hi.md) | [Türkçe](README.tr.md)

Ferramenta de código aberto em PowerShell para **otimizar, limpar e reparar o Windows**. Ela analisa o seu PC, explica o que está errado e corrige só o que você escolher: inicialização lenta, disco C: cheio, erros do Windows Update, arquivos DLL ausentes, problemas de drivers, Wi-Fi e Bluetooth que caem. Cada alteração é registrada e pode ser **desfeita**.

Sem instalador, sem anúncios, sem telemetria. Execute um arquivo `.bat` e escolha: menu no console, janela moderna no navegador ou janela clássica do Windows.

![Resultados do Doutor](ui-doctor-ar.png)

## Recursos

- **Doutor:** verifica atualizações, drivers, DLLs, saúde do disco, segurança e log de eventos, e corrige o que você escolher.
- **Limpador de PC:** temporários, cache de atualizações e de navegadores, análise de espaço, TRIM para SSD, remoção de apps pré-instalados.
- **Acelerar o Windows:** plano de energia de alto desempenho, gerenciador de inicialização, serviços opcionais.
- **Atualizar e reparar:** apps via winget, SFC e DISM, backup e restauração de drivers.
- **Rede:** correções de Wi-Fi e Bluetooth, teste de DNS, verificação do arquivo hosts e do canal Wi-Fi.
- **Segurança:** firewall, SMBv1, Área de Trabalho Remota, UAC e Defender reversível.
- **Segurança primeiro:** modo de teste, ponto de restauração, registro para desfazer.

## Problemas comuns

- **Bluetooth conectado mas sem som** no Windows 10: correção de Bluetooth sem som.
- **Wi-Fi cai ou trava:** reinício rápido do Wi-Fi e desativar a economia de energia.
- **Disco C: cheio e PC lento:** limpar arquivos, liberar espaço, programas de inicialização.
- **Windows Update travado** ou **DLL ausente** (d3dx9 etc.): o Doutor resolve.
- **Remover bloatware** e ativar ou desativar o Windows Defender de forma reversível.

## Início rápido

1. Baixe o ZIP da [versão mais recente](https://github.com/Ebnhussein/TurboOpt/releases/latest).
2. Execute `TurboOptimizer.bat`.
3. Escolha navegador, janela ou console. Experimente primeiro o **modo de teste** (não altera nada).

Requisitos: Windows 10 (1809 ou mais recente) ou Windows 11, e permissão de administrador. Licença: MIT.
