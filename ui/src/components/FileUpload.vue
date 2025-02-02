<template>
  <div class="file-upload-container">
    <!-- Left White Box (File Upload) -->
    <div class="file-upload">
      <h2>Upload File</h2>
      <!-- Success Message -->
      <transition name="fade">
        <div v-if="successMessage" class="success-message">
          {{ successMessage }}
        </div>
      </transition>
      <!-- Custom Drag-and-Drop Zone -->
      <div
        class="drag-drop-zone"
        @dragover.prevent
        @drop="handleDrop"
        @click="triggerFileInput"
        :class="{ 'dragging': isDragging }"
      >
        <p v-if="!file">Drag & drop or click</p>
        <p v-else>{{ file.name }}</p>
      </div>
      <input type="file" ref="fileInput" @change="handleFileChange" style="display: none;" />
      <button @click="uploadFile" :disabled="!file">Upload</button>
    </div>

    <!-- Right White Box (Text Area and Submit Button) -->
    <div class="text-box">
      <h2>Paste text</h2>
      <transition name="fade">
        <div v-if="textSuccessMessage" class="success-message">
          {{ textSuccessMessage }}
        </div>
      </transition>
      <textarea
        v-model="textInput"
        rows="10"
        placeholder="Paste your text here"
        class="text-area"
      ></textarea>
      <!-- Submit Button -->
      <button class="submit-button" @click="submitText">Submit</button>
    </div>
  </div>
</template>

<script>
import axios from 'axios';

export default {
  data() {
    return {
      file: null,
      isDragging: false,
      textInput: "", // Text input model
      successMessage: "", // Success message state
      textSuccessMessage: ""
    };
  },
  methods: {
    handleFileChange(event) {
      this.file = event.target.files[0];
    },
    triggerFileInput() {
      this.$refs.fileInput.click();
    },
    async uploadFile() {
      if (!this.file) {
        alert('Please select a file first!');
        return;
      }

      const formData = new FormData();
      formData.append('file', this.file);

      try {
        await axios.post('http://localhost:5000/file', formData, {
          headers: {
            'Content-Type': 'multipart/form-data',
            'accept':'application/json,text/plain'
          },
          maxContentLength: Infinity,
          maxBodyLength: Infinity
        });

        // Show success message
        this.successMessage = "File uploaded successfully!";
        
        // Hide message after 5 seconds
        setTimeout(() => {
          this.successMessage = "";
        }, 1000);
      } catch (error) {
        console.error('Error uploading file:', error);
        alert('Error uploading file.');
      }
    },
    handleDrop(event) {
      this.isDragging = false;
      const droppedFile = event.dataTransfer.files[0];
      if (droppedFile) {
        this.file = droppedFile;
      }
    },
    submitText() {
      if (!this.textInput.trim()) {
        alert('Please enter some text first!');
        return;
      }
      
      this.textSuccessMessage = "Text submitted successfully!";
    
      setTimeout(() => {
        this.textSuccessMessage = "";
      }, 1000);

      fetch('http://localhost:5000/text', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: this.textInput,
      })
    }
  }
};
</script>

<style scoped>
.file-upload-container {
  display: flex;
  justify-content: space-between;
  gap: 20px;
  width: 1000px;
  margin: 0 auto;
  padding: 20px;
  box-sizing: border-box;
}

.file-upload,
.text-box {
  width: 48%;
  padding: 20px;
  background-color: #f8f9fa;
  border-radius: 8px;
  box-shadow: 0 4px 10px rgba(0, 0, 0, 0.1);
  box-sizing: border-box;
}

h2 {
  font-size: 24px;
  margin-bottom: 20px;
  color: #333;
  text-align: center;
}

.custom-file-button {
  display: inline-block;
  padding: 12px 24px;
  background-color: #6200ea;
  color: white;
  font-size: 16px;
  font-weight: 500;
  text-align: center;
  border-radius: 4px;
  cursor: pointer;
  transition: background-color 0.3s ease;
  margin-bottom: 20px;
}

.custom-file-button:hover {
  background-color: #3700b3;
}

button {
  padding: 12px 24px;
  background-color: #007bff;
  border: none;
  border-radius: 4px;
  color: white;
  font-size: 16px;
  cursor: pointer;
  transition: background-color 0.3s ease;
}

button:hover {
  background-color: #0056b3;
}

button:disabled {
  background-color: #cccccc;
  cursor: not-allowed;
}

.drag-drop-zone {
  width: 100%;
  padding: 30px;
  border: 2px dashed #007bff;
  border-radius: 8px;
  background-color: #f0f8ff;
  cursor: pointer;
  transition: background-color 0.3s ease;
  box-sizing: border-box;
  margin-bottom: 20px;
}

.drag-drop-zone p {
  font-size: 16px;
  color: #007bff;
}

.drag-drop-zone.dragging {
  background-color: #e1f0ff;
}

.drag-drop-zone:hover {
  background-color: #e1f0ff;
}

.text-area {
  width: 100%;
  margin-bottom: 20px;
  border-radius: 4px;
  border: 1px solid #ccc;
  resize: vertical;
  font-size: 16px;
}

/* Success Message */
.success-message {
  background-color: #28a745;
  color: white;
  padding: 10px;
  border-radius: 4px;
  text-align: center;
  margin-bottom: 10px;
  font-size: 16px;
}

/* Fade-in and fade-out transition */
.fade-enter-active, .fade-leave-active {
  transition: opacity 0.5s;
}
.fade-enter, .fade-leave-to {
  opacity: 0;
}
</style>
