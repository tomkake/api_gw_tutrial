# Google Sign-In + API Gateway + 2つの Lambda

認証・認可を1つ目の Lambda に集約し、1つ目と2つ目の両方に業務用エンドポイントを持つ PoC です。2つ目は業務処理だけを担当します。Google の **ID Token** を利用し、Amazon Cognito は使用しません。

```text
Browser → Google Identity Services → Google ID Token
   |
   | Authorization: Bearer <ID Token>
   v
API Gateway HTTP API
   |
   +→ Lambda 1（REQUEST Lambda Authorizer）
   |    Google の署名・issuer・audience・有効時刻・許可メールを検査
   |    ├ 拒否 → API Gateway が403、Lambda 2 は呼ばない
   |    └ 許可
   +→ GET /private   → Lambda 1（業務処理）
   └→ GET /secondary → Lambda 2（業務処理）
   どちらもメッセージと request ID を返す
```

**認証・認可には Lambda Authorizer を使用します。** `GET /private` は認証・認可後に1つ目の Lambda の業務処理へ、`GET /secondary` は認証・認可後に2つ目の Lambda へ接続します。`/private` では1つ目が authorizer と integration として計2回呼ばれます。イベントの `type=REQUEST` を authorizer 呼出しとして扱い、HTTP API integration イベントは業務用ハンドラーへ振り分けます。

## 各 Lambda の役割と呼出し権限

| 対象 | ソース | バイナリ / zip | 役割 |
|---|---|---|---|
| Lambda 1 | `lambda/` | `.build/bootstrap` / `.build/lambda.zip` | 認証・認可と `/private` の業務処理 |
| Lambda 2 | `lambda-secondary/` | `.build/secondary/bootstrap` / `.build/secondary-lambda.zip` | 業務処理専用 |

ソース、Go モジュール、依存 lock、ビルド、テスト、実行 role、log group は独立しています。

1つ目は Google の Go ライブラリ `idtoken.Validate` で Google 公開鍵による署名、audience、有効期限を確認し、issuer、発行時刻、subject、メール、`email_verified` も検査します。issuer は `https://accounts.google.com`、audience は設定した Google OAuth Web クライアント ID です。許可するメールは `.env` の `TF_VAR_allowed_email` から Lambda 1 の `ALLOWED_EMAIL` へ渡します。JWT/メール設定がない場合も許可しません。[Google の ID Token 検証手順](https://developers.google.com/identity/gsi/web/guides/verify-google-id-token)、[Go 検証ライブラリ](https://pkg.go.dev/google.golang.org/api/idtoken)

Lambda Authorizer は payload 2.0 の simple response で許可・拒否を返します。毎回有効期限と認可を評価するため、authorizer の結果キャッシュは無効にしています。Authorization header がない場合は API Gateway が401を返します。header があるが token やメール条件が不正な場合は Lambda 1 が拒否し、API Gateway が403を返します。[AWS Lambda Authorizer 仕様](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-lambda-authorizer.html)

1つ目の業務用応答は `Hello from the first Lambda!` と request ID です。1つ目は authorizer が返した `authorized=true` の結果を確認して業務処理を実行します。authorizer context に token・メール・subject は渡しません。

2つ目は token、claims、メール設定、authorizer context を読みません。次の JSON だけを返します。

```json
{
  "message": "Hello from the second Lambda!",
  "request_id": "example-request-id"
}
```

2つ目に Lambda Function URL や認証なし route は作成しません。Lambda の resource policy は、このアカウントのこの API Gateway の `GET /secondary` からの呼出しだけを許可します。1つ目の resource policy は、この API の authorizer と `GET /private` からの呼出しだけを許可します。実行 role は各関数自身の log stream の作成・書込みだけを許可し、関数同士を直接呼ぶ権限は付与しません。

これは一般の API 利用者向けの入口を API Gateway に限定する設定です。AWS IAM で別途 `lambda:InvokeFunction` を持つ管理者等による直接呼出しは別の権限経路です。API 利用者にはその IAM 権限を付与しないでください。

## 準備

必要なツール: Go 1.26 以上、Terraform 1.9 以上かつ 2.0 未満、AWS CLI v2、Python 3.9 以上、Make、ブラウザ。

### Google OAuth

PoC 用 Google Cloud プロジェクトで Google Auth Platform のブランド情報、対象ユーザー、OAuth クライアントを設定します。テスト中の外部アプリでは利用者をテストユーザーに追加します。

- クライアントの種類: **ウェブ アプリケーション**
- 承認済み JavaScript 生成元: `http://localhost:8000` と `http://localhost`
- ページを開く URL: `http://localhost:8000`
- popup と callback を使用するため、リダイレクト URI と client secret は不要

Google Identity Services callback の `response.credential` が ID Token です。OAuth access token を取得するコードはありません。[Google セットアップ](https://developers.google.com/identity/gsi/web/guides/get-google-api-clientid)

### ローカル設定と AWS の分離

PoC 用の AWS 認証を使います。Terraform provider は `aws_account_id` で指定したアカウント以外を拒否します。既存の本番 state/backend をこのディレクトリにコピーしないでください。リソース名にはランダム suffix を付けています。

```bash
export AWS_PROFILE=your-poc-profile
aws sso login --profile "$AWS_PROFILE" # SSO の場合
aws sts get-caller-identity
# 新しい環境でのみコピー。設定済みのファイルは上書きしない
cp terraform.tfvars.example terraform.tfvars
cp .env.example .env
```

`terraform.tfvars` に実際の AWS アカウント ID と Google Web クライアント ID を設定します。`.env` に許可する1つのメールを指定します。例示値はすべてダミーです。

```dotenv
TF_VAR_allowed_email=allowed@example.invalid
```

`make` は `.env` を読み込み、Terraform と検証スクリプトに渡します。Terraform/Python を直接実行する場合は、先に `set -a; source .env; set +a` で読み込みます。メールは Terraform の sensitive 変数として通常の plan 表示から伏せます。state と保存 plan には実際の値が含まれるため Git 対象外です。

`.gitignore` は `.env` と `.env.*`、tfvars（JSON形式も）、state/backup/lock/plan、`.terraform/`、`.build/`、Python cache、ログを除外します。`.env.example` と `terraform.tfvars.example` は共有できます。

## 構築・変更反映

```bash
make init
make check
make plan
terraform show .build/poc.tfplan
terraform apply .build/poc.tfplan
make serve
```

plan の変更内容と対象アカウントを確認してから適用します。古い保存 plan は適用せず、両関数をビルドする `make plan` で作り直してください。

`make build-primary` と `make build-secondary` で個別ビルドもできます。Go バイナリは Linux/arm64、zip 内の名前は `bootstrap`、runtime は provided.al2023 です。

`make serve` は確認ページと公開設定だけをローカル配信します。state や `.env` は配信しません。ブラウザで `http://localhost:8000` を開きます。

1. ログイン前に「1つ目を Token なしで呼ぶ（401 確認）」と「2つ目を Token なしで呼ぶ（401 確認）」を押し、両方401になることを確認します。2つ目のボタンは `/secondary` へ Authorization header を付けずにリクエストします。
2. 設定した許可メールで Google ログインし、画面上の7 claims を確認します。
3. 「1つ目の Lambda を呼ぶ」で `/private` の200と1つ目の応答を、「2つ目の Lambda を呼ぶ」で `/secondary` の200と2つ目の応答を確認します。
4. 「検証用 ID Token をコピー」し、別端末の `make test` の非表示プロンプトに貼り付けます。
5. 別アカウントでも試すと、API Gateway から403が返ります。

表示する claims は `iss`、`aud`、`sub`、`email`、`email_verified`、`iat`、`exp` です。ブラウザの表示用デコードは認証判断ではありません。認証・認可の最終判断は Lambda 1 が行います。業務応答には claims を含めません。token はページのメモリに保持し、localStorage/cookie に保存しません。コピー後のクリップボードは検証後に消去します。

CORS は API Gateway が `http://localhost:8000` の GET と Authorization header を許可します。OPTIONS は API Gateway が応答します。[AWS HTTP API CORS](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-cors.html)

## 実環境検証

`make test` は両 route の計8ケースを確認します。

| 入力 | HTTP | Lambda 1 | Lambda 2 |
|---|---:|---|---|
| header なし | 401 | 呼ばれない | 呼ばれない |
| 不正文字列 | 403 | 拒否 | 呼ばれない |
| 署名破損 ID Token | 403 | 拒否 | 呼ばれない |
| 正規 token・許可メール・確認済み | 200 | 許可 | 業務応答 |
| 正規 token・別メールまたは未確認 | 403 | 拒否 | 呼ばれない |

表の Lambda 1 は authorizer としての動作です。`/private` の成功時には Lambda 1 の業務処理が続き、Lambda 2 は呼ばれません。`/secondary` の成功時に Lambda 2 が呼ばれます。

1回の実行は入力した1つの token について確認します。正規 token の期待値はメールと確認状態に応じて200/403になります。

各応答の `apigw-requestid` と3つの CloudWatch log group を照合します。拒否時は業務 integration status が `-` で、どちらの関数にも業務実行ログがないことが必要です。header ありの拒否には Lambda 1 の `kind=authorization`・`authorized=false` ログ、成功には `authorized=true` と対象関数の `kind=business` ログが必要です。同じ request ID で Lambda 1 が2回呼ばれても、`kind` ごとに分けて照合します。最大180秒待って証拠が不足する場合は失敗します。

成功時のみ `.build/verification.json` に検証時刻、API URL、公開 client ID、確認した claim 名、HTTP 結果、request ID、各ログ有無を保存します。token やメール・subject の値は保存しません。再実行時は古い成功レポートを削除します。API/関数ログにも token やメールを出しません。ローカル mock テストは実 AWS 成功の証明にはなりません。

期限切れの独立検証は、正規 token の実際の `exp` を過ぎてから実行します。payload 変更は署名破損テストになるため独立した期限切れ検証にはなりません。

## 削除

```bash
make destroy-plan # 削除予定のみ。削除は実行しない
make destroy      # 確認プロンプト承認後に削除
```

この state の2つの Lambda、HTTP API、IAM role/policy、ログ等を削除します。Google OAuth クライアントは別途削除します。state は削除完了まで保管してください。

## GitHub へ push

共有するのはソースコードとダミー値の設定例だけです。実値を含む `.env`、tfvars、state、plan、検証結果、ローカル検証メモは `.gitignore` で除外します。push 前にステージ済みの内容を確認してください。

```bash
git remote -v
git add .
git diff --cached --stat
git diff --cached
git commit -m "Separate authorization and business Lambda"
make push
```

push と AWS の apply/destroy は別の操作です。
