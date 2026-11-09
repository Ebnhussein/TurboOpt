# Turbo Optimizer: ücretsiz Windows 10/11 optimizasyon, temizlik ve onarım aracı

[English](../README.md) | [العربية](README.ar.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt.md) | [Русский](README.ru.md) | [简体中文](README.zh.md) | [हिन्दी](README.hi.md) | **Türkçe**

PowerShell ile yazılmış açık kaynaklı bir araç: **Windows'u optimize eder, temizler ve onarır**. Bilgisayarınızı tarar, sorunu açıklar ve yalnızca seçtiğinizi düzeltir: yavaş açılış, dolu C: sürücüsü, Windows Update hataları, eksik DLL dosyaları, sürücü sorunları, sürekli kopan Wi-Fi ve Bluetooth. Her değişiklik kaydedilir ve **geri alınabilir**.

Kurulum yok, reklam yok, telemetri yok. PowerShell'e tek satır yapıştırın: araç indirilir, tarayıcıda modern bir pencerede açılır ve ne istediğinizi sorar.

![Doktor sonuçları](ui-doctor-ar.png)

## Özellikler

- **Doktor:** güncellemeleri, sürücüleri, DLL'leri, disk sağlığını, güvenliği ve olay günlüğünü tarar, seçtiklerinizi düzeltir.
- **PC temizleyici:** geçici dosyalar, güncelleme ve tarayıcı önbellekleri, alan analizi, SSD için TRIM, önceden yüklü uygulamaları kaldırma.
- **Windows'u hızlandır:** yüksek performans güç planı, başlangıç yöneticisi, isteğe bağlı hizmetler.
- **Güncelleme ve onarım:** winget ile uygulama güncelleme, SFC ve DISM, sürücü yedekleme ve geri yükleme.
- **Ağ:** Wi-Fi ve Bluetooth düzeltmeleri, DNS hız testi, hosts dosyası ve Wi-Fi kanal kontrolü.
- **Güvenlik:** güvenlik duvarı, SMBv1, Uzak Masaüstü, UAC ve geri alınabilir Defender aç/kapat.
- **Önce güvenlik:** deneme modu, geri yükleme noktası, geri alma günlüğü.

## Sık karşılaşılan sorunlar

- **Windows 10'da Bluetooth bağlı ama ses yok:** Bluetooth sessizlik düzeltmesi.
- **Wi-Fi kopuyor veya donuyor:** Wi-Fi hızlı sıfırlama, güç tasarrufunu durdurma.
- **C: sürücüsü dolu, bilgisayar yavaş:** dosyaları temizle, yer aç, başlangıç programları.
- **Windows Update takıldı** veya **DLL eksik** (d3dx9 vb.): Doktor düzeltir.
- **Gereksiz uygulamaları (bloatware) kaldırın** ve Windows Defender'ı geri alınabilir şekilde kapatıp açın.

## Hızlı başlangıç

```powershell
irm https://raw.githubusercontent.com/Ebnhussein/TurboOpt/main/install.ps1 | iex
```

PowerShell'i açın ve bu satırı yapıştırın. Araç indirilir, tarayıcıda açılır ve ne istediğinizi sorar (otomatik bakım dahil: haftalık temizlik veya günlük izleme). Önce **deneme modunu** deneyin.
