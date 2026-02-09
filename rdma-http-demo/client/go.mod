module rdma-http-demo/client

go 1.23

require (
	github.com/aws/aws-sdk-go-v2/config v1.32.3
	github.com/aws/aws-sdk-go-v2/credentials v1.19.7
	github.com/aws/aws-sdk-go-v2/service/s3 v1.88.3
	github.com/aws/smithy-go v1.24.0
)

require (
	github.com/aws/aws-sdk-go-v2 v1.41.1 // indirect
	github.com/aws/aws-sdk-go-v2/aws/protocol/eventstream v1.7.4 // indirect
	github.com/aws/aws-sdk-go-v2/feature/ec2/imds v1.18.17 // indirect
	github.com/aws/aws-sdk-go-v2/internal/configsources v1.4.17 // indirect
	github.com/aws/aws-sdk-go-v2/internal/endpoints/v2 v2.7.17 // indirect
	github.com/aws/aws-sdk-go-v2/internal/ini v1.8.4 // indirect
	github.com/aws/aws-sdk-go-v2/internal/v4a v1.4.17 // indirect
	github.com/aws/aws-sdk-go-v2/service/internal/accept-encoding v1.13.4 // indirect
	github.com/aws/aws-sdk-go-v2/service/internal/checksum v1.9.8 // indirect
	github.com/aws/aws-sdk-go-v2/service/internal/presigned-url v1.13.17 // indirect
	github.com/aws/aws-sdk-go-v2/service/internal/s3shared v1.19.17 // indirect
	github.com/aws/aws-sdk-go-v2/service/signin v1.0.5 // indirect
	github.com/aws/aws-sdk-go-v2/service/sso v1.30.9 // indirect
	github.com/aws/aws-sdk-go-v2/service/ssooidc v1.35.13 // indirect
	github.com/aws/aws-sdk-go-v2/service/sts v1.41.6 // indirect
)

replace github.com/aws/aws-sdk-go-v2 => ../../aws-sdk-go-v2

replace github.com/aws/aws-sdk-go-v2/config => ../../aws-sdk-go-v2/config

replace github.com/aws/aws-sdk-go-v2/credentials => ../../aws-sdk-go-v2/credentials

replace github.com/aws/aws-sdk-go-v2/feature/ec2/imds => ../../aws-sdk-go-v2/feature/ec2/imds

replace github.com/aws/aws-sdk-go-v2/internal/configsources => ../../aws-sdk-go-v2/internal/configsources

replace github.com/aws/aws-sdk-go-v2/internal/endpoints/v2 => ../../aws-sdk-go-v2/internal/endpoints/v2

replace github.com/aws/aws-sdk-go-v2/internal/ini => ../../aws-sdk-go-v2/internal/ini

replace github.com/aws/aws-sdk-go-v2/internal/v4a => ../../aws-sdk-go-v2/internal/v4a

replace github.com/aws/aws-sdk-go-v2/aws/protocol/eventstream => ../../aws-sdk-go-v2/aws/protocol/eventstream

replace github.com/aws/aws-sdk-go-v2/service/internal/accept-encoding => ../../aws-sdk-go-v2/service/internal/accept-encoding

replace github.com/aws/aws-sdk-go-v2/service/internal/checksum => ../../aws-sdk-go-v2/service/internal/checksum

replace github.com/aws/aws-sdk-go-v2/service/internal/presigned-url => ../../aws-sdk-go-v2/service/internal/presigned-url

replace github.com/aws/aws-sdk-go-v2/service/internal/s3shared => ../../aws-sdk-go-v2/service/internal/s3shared

replace github.com/aws/aws-sdk-go-v2/service/signin => ../../aws-sdk-go-v2/service/signin

replace github.com/aws/aws-sdk-go-v2/service/s3 => ../../aws-sdk-go-v2/service/s3

replace github.com/aws/aws-sdk-go-v2/service/sso => ../../aws-sdk-go-v2/service/sso

replace github.com/aws/aws-sdk-go-v2/service/ssooidc => ../../aws-sdk-go-v2/service/ssooidc

replace github.com/aws/aws-sdk-go-v2/service/sts => ../../aws-sdk-go-v2/service/sts
