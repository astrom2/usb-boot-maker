# USB Boot Maker

A single-file Windows tool for making a bootable USB from an ISO or IMG image, either Windows (including Windows Server) or Linux. You don't install anything. Download one file and run it.

<div dir="rtl">

## بالعربي

أداة من ملف واحد تشتغل على ويندوز. تسوي فلاشة إقلاع (Bootable USB) من صورة ويندوز أو Windows Server أو لينكس.

**المميزات:**
- واجهة رسومية تسحب لها ملف الـ ISO أو IMG وتفلته.
- تعرض الفلاشات USB فقط، وما تعرض الأقراص الداخلية أبداً.
- تعرف نوع الصورة لحالها وتختار طريقة الحرق:
  - **ويندوز:** فورمات FAT32 أو NTFS، ثم نسخ الملفات. إذا كان ملف `install.wim` أكبر من 4GB تقسّمه تلقائياً بأداة DISM.
  - **لينكس وصور IMG:** كتابة خام (DD) قطاع بقطاع، مثل Rufus DD و balenaEtcher.
- تطلب تأكيد قبل ما تمسح أي شي، وتتحقق مرة ثانية أن القرص USB وأنه مو قرص النظام.

**طريقة الاستخدام:**
1. نزّل ملف [`USB-Boot-Maker.bat`](USB-Boot-Maker.bat).
2. اضغط عليه مرتين، أو اسحب ملف ISO وأفلته على أيقونته.
3. اختر الصورة والفلاشة وطريقة الحرق، ثم اضغط **START** ووافق على صلاحية المسؤول.

**ملاحظات:**
- لو طلعت لك رسالة "Windows protected your PC"، اضغط More info ثم Run anyway.
- بعد حرق لينكس، إذا طلب منك الويندوز فورمات الفلاشة، اضغط **Cancel**.
- الصور المضغوطة مثل `.img.xz` و `.zip` لازم تفك ضغطها أولاً.

</div>

## English

### Features
- A drag-and-drop window for choosing the ISO or IMG file.
- Only USB disks are listed. Internal and system disks never appear.
- The image type is detected automatically and the matching write mode is selected:
  - **Windows mode:** the USB is formatted as FAT32 (UEFI + Legacy) or NTFS (Legacy/CSM), then the ISO files are copied. When `install.wim` is larger than 4 GB, it is split with DISM automatically.
  - **DD mode:** used for Linux hybrid ISOs and `.img` files. The image is written raw, sector by sector, the same way as Rufus DD mode or balenaEtcher.
- The tool asks for confirmation before erasing anything. Right before writing, it re-checks that the target is a USB disk, that it is not the system disk, and that it is still the same drive you selected.

### Usage
1. Download [`USB-Boot-Maker.bat`](USB-Boot-Maker.bat).
2. Double-click it, or drop an ISO/IMG file onto its icon.
3. Choose the image, the USB drive and the write mode, click **START**, then accept the Administrator (UAC) prompt.

### How it works
The `.bat` file is a batch/PowerShell hybrid. The first few lines are a batch launcher, which PowerShell reads as a comment. The launcher runs the rest of the same file as PowerShell. The window runs without admin rights, because Windows blocks drag & drop into elevated windows. The actual disk work runs in a separate elevated window.

### Notes
- Requires Windows 10/11 or Windows Server with the built-in Windows PowerShell 5.1.
- If SmartScreen shows "Windows protected your PC", click **More info**, then **Run anyway**.
- After a Linux image is written, Windows may ask to format the USB. Click **Cancel**. Windows can't read Linux partitions, and that's expected.
- Compressed images (`.img.xz`, `.zip`, `.gz`) must be extracted first.

> ⚠️ This tool erases the selected USB drive. Double-check the drive before you click START.
