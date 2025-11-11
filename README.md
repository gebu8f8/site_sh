# Nginx 全自動建站工具（支援 Certbot + WordPress）By gebu8f

# 站點管理器所整合的所有腳本
資料庫管理器：https://github.com/gebu8f8/db_sh

防火牆管理器：https://github.com/gebu8f8/firewall_sh

Docker管理器：
https://github.com/gebu8f8/docker_sh

# 注意 !
- 本腳本採取選擇性設計原則：  
- 僅加入經過測試、穩定、必要的功能。  
- 對於可能影響系統相容性或造成混亂的需求，將不予加入，並在必要時說明理由。  
- 穩定性優先於功能多樣性，是本腳本的核心理念。

# 🔐 授權 License

本專案以 [Apache License 2.0](./LICENSE) 授權，您可以自由使用、修改、商用或學術用途，條件如下：

- **請保留原始作者署名（標註我）**
- **若有修改，請明確標註變更**
- **禁止移除授權資訊後冒充原作者**
- **不提供任何保固或技術責任**

違反者我將保留依法提出 DMCA 下架的權利。

# 介紹

這是一套純本地部署（非 Docker）的 Nginx + SSL + WordPress 自動化建站腳本，專為 VPS 多系統環境設計，支援 **Debian / CentOS / Alpine Linux** 三大主流系統，讓你一鍵完成完整建站流程。

# 📌 備註

我目前已將專案主力倉庫搬遷至 GitHub，原本長期維護於 GitLab（提交數已累積超過 200 次以上），目前此 GitHub 倉庫屬於新建立版本，因此提交紀錄較少屬正常情況。

🔗 原始 GitLab 倉庫：https://gitlab.com/gebu8f/sh

🔗 GitHub 倉庫：https://github.com/gebu8f8/site_sh

---

## 特點亮點

### ✅ 本地版非 Docker，更穩定可控
與部分大佬的 Docker 方案不同，本專案專注於本地安裝，**無容器依賴、無封裝黑盒**，配置與系統高度整合，便於排錯與維護。

### ✅ 跨三大主流系統自動適配
自動偵測系統，根據環境自動採用：
- apt（Debian/Ubuntu）
- yum / dnf（CentOS/RHEL）
- apk（Alpine）

### ✅ 支援多家 CA 與 DNS / HTTP 驗證
- 憑證機構選擇：
  - Let's Encrypt
  - ZeroSSL
  - Google Trust Services
- 驗證方式：
  - Cloudflare DNS（API Token 驗證）
  - HTTP（Webroot / nginx 模組）

### ✅ WordPress 一鍵部署 + 自動資料庫建立
- 自動建立資料庫與帳號密碼
- 可保留語言選擇頁面（非全自動跳過）
- Nginx 配置自動完成

### ✅ 全面錯誤處理與修復
- 權限修復（避免 500 錯誤）
- fastcgi socket 錯誤預防
- certbot 自動續簽 + nginx reload
- 自動開放 / 關閉 firewall（ufw / iptables / firewalld）

---

## 初次運行時需要下方指令,接下來可用site呼叫

## 安裝與使用
```
bash <(curl -sL https://sh.gebu8f.com/site)
```
之後即可用site使用之

---
💡 **支持本計畫**

如果你覺得這個工具幫助到你了，  
也歡迎在下方自願性支持我繼續開源維護：

→ [前往支持頁面](https://ko-fi.com/gebu8f)

我沒有強制贊助，也不會推廣付費功能。  
因為我相信：**願意支持的你，一定會自己找到這段話。**
