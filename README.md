# Secure Serverless File Upload System (AWS)

## Course Information
- **Course Name:** Cloud Computing and Security
- **Course Code:** 25541

## Team Members
- Adam Mohammad – 20220032  
- Ahmad Al-Khatib – 20220692  

---

## 📌 Project Overview
This project implements a **secure serverless file upload system** using AWS managed services.  
Users upload files through a web dashboard, files are securely stored in Amazon S3, audit logs are saved to DynamoDB, and email notifications are sent using Amazon SNS.

The system follows **serverless architecture principles**, meaning:
- No servers are managed by the developers
- Automatic scaling
- Pay-per-use pricing
- Event-driven execution

---

## 🏗️ Architecture Overview

**Main AWS Services Used:**
- Amazon S3 (Secure File Storage)
- AWS Lambda (Backend Logic)
- Amazon DynamoDB (Audit Logs)
- Amazon SNS (Email Notifications)
- Amazon API Gateway (REST APIs)
- Amazon CloudWatch (Monitoring & Logs)

📊 The full architecture flowchart is available in the `/diagrams` folder.

---

## 🔁 System Workflow

1. User opens the web dashboard (`dashboard.html`)
2. User selects a file and clicks upload
3. Dashboard calls **GenerateUploadLink Lambda**
4. Lambda returns a **pre-signed S3 upload URL**
5. File uploads directly to S3
6. S3 triggers **S3-Audit-Logger Lambda**
7. Audit data is stored in DynamoDB
8. SNS sends an email notification
9. Dashboard fetches history from **ListAuditLogs Lambda**

---

## 🧠 Lambda Functions

### 1️⃣ GenerateUploadLink
- Generates secure pre-signed S3 upload URLs
- Prevents direct S3 access
- Enforces upload expiration

### 2️⃣ S3-Audit-Logger
- Triggered automatically when a file is uploaded
- Stores file metadata in DynamoDB
- Sends SNS email notifications

### 3️⃣ ListAuditLogs
- Retrieves upload history from DynamoDB
- Serves audit data to the dashboard

---

## 🔐 Security Features

- Pre-signed URLs (temporary upload access)
- No public S3 bucket access
- IAM least-privilege roles
- Audit logging for accountability
- Email alerts via SNS
- CloudWatch logging for monitoring

---

## 📊 Dashboard Features

- Drag & drop upload
- Upload progress bar
- Search & sorting
- Real-time audit history
- Responsive UI (Bootstrap)
- No backend credentials exposed

---

## 🧪 Testing & Monitoring

- Upload verification via dashboard & curl
- CloudWatch logs for all Lambda executions
- DynamoDB item validation
- SNS email delivery confirmation

---

## 🚀 Why This Project Is Serverless

✔ No EC2 instances  
✔ No server management  
✔ Event-driven execution  
✔ Automatic scaling  
✔ Fully managed AWS services  

---

