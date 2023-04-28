// Copyright 2020 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package KeepAlive

// [START storage_list_files]
import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"

	"cloud.google.com/go/storage"
	"github.com/gtuk/discordwebhook"
	"google.golang.org/api/iterator"
)

func discord() {
	//https://github.com/gtuk/discordwebhook
	var username = "Keep Alive"
	var content = "HomeLab Cannot Reach Internet!"
	var url = "https://discord.com/api/webhooks/" + os.Getenv("DISCORD")

	message := discordwebhook.Message{
		Username: &username,
		Content:  &content,
	}

	err := discordwebhook.SendMessage(url, message)
	if err != nil {
		log.Fatal(err)
	}
}

// listFiles lists objects within specified bucket.
func listFiles(bucket string, allowed_delta string) error {
	// bucket := "bucket-name"
	ctx := context.Background()
	client, err := storage.NewClient(ctx)
	if err != nil {
		return fmt.Errorf("storage.NewClient: %v", err)
	}
	defer client.Close()

	ctx, cancel := context.WithTimeout(ctx, time.Second*10)
	defer cancel()

	keepAlive := 0

	it := client.Bucket(bucket).Objects(ctx, nil)
	for {
		attrs, err := it.Next()
		if err == iterator.Done {
			break
		}
		if err != nil {
			return fmt.Errorf("Bucket(%q).Objects: %v", bucket, err)
		}

		fileName, _ := strconv.Atoi(attrs.Name)
		if fileName > keepAlive {
			keepAlive = fileName
		}
	}

	epoch, _ := strconv.Atoi(strconv.FormatInt(time.Now().UTC().Unix(), 10))
	max_delta, _ := strconv.Atoi(allowed_delta)
	keepAlive = epoch - keepAlive
	fmt.Println("Keep Alive: " + strconv.Itoa(keepAlive))
	fmt.Println("ALlowed Delta: " + strconv.Itoa(max_delta))

	if keepAlive > max_delta {
		fmt.Println("SERVER DOWN!")
		discord()
	}

	return nil
}

// [END storage_list_files]

func KeepAlive(w http.ResponseWriter, r *http.Request) {
	listFiles(os.Getenv("GCS_BUCKET"), os.Getenv("ALLOWED_DELTA"))
}
