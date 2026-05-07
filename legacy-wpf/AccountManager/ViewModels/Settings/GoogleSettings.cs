using MaterialDesignThemes.Wpf;
using Microsoft.Win32;
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Input;

//namespace AccountManager.ViewModels.Settings
//{
//    class GoogleSettings : INotifyPropertyChanged
//    {
//        State.Google.GoogleState state;

//        public IAsyncCommand TestConnectionCommand { get; set; }
//        public ICommand ImportSecretCommand { get; set; }

//        public GoogleSettings()
//        {
//            state = State.App.Instance.Google;
//            this.TestConnectionCommand = new RelayAsyncCommand(TestConnection);
//            this.ImportSecretCommand = new RelayCommand(ImportSecret);

//            if (state.IsSecretSet)
//            {
//                SecretStatus = "Secret is Set";
//            } else
//            {
//                SecretStatus = "Secret is not Set";
//            }
//        }

//        private async Task TestConnection()
//        {
//            ShowConnectIndicator = true;

//            await Task.Run(() =>
//            {
//                state.Connect();
//                if (state.Connection.Value != AccountApi.ConnectionState.OK) ConnectIcon = PackIconKind.CloudOffOutline;
//                else ConnectIcon = PackIconKind.CloudTick;
//            });

//            ShowConnectIndicator = false;
//        }

//        private void ImportSecret()
//        {
//            OpenFileDialog openFileDialog = new OpenFileDialog
//            {
//                Filter = "Json Files (*.json)|*.json|All Files (*.*)|*.*"
//            };
//            if (openFileDialog.ShowDialog() == true)
//            {
//                string content = File.ReadAllText(openFileDialog.FileName);
//                state.SetSecret(content);
//                SecretStatus = "Secret is Set";
//            }
//        }

//        public event PropertyChangedEventHandler PropertyChanged = (sender, e) => { };

//        string secretStatus;
//        public string SecretStatus
//        {
//            get => secretStatus;
//            set
//            {
//                secretStatus = value;
//                PropertyChanged(this, new PropertyChangedEventArgs(nameof(secretStatus)));
//            }
//        }

//        bool showConnectIndicator = false;
//        public bool ShowConnectIndicator
//        {
//            get => showConnectIndicator;
//            set
//            {
//                showConnectIndicator = value;
//                PropertyChanged(this, new PropertyChangedEventArgs(nameof(ShowConnectIndicator)));
//            }
//        }

//        private PackIconKind connectIcon = PackIconKind.CloudQuestion;
//        public PackIconKind ConnectIcon
//        {
//            get => connectIcon;
//            set
//            {
//                connectIcon = value;
//                PropertyChanged(this, new PropertyChangedEventArgs(nameof(ConnectIcon)));
//            }
//        }

//        public string AppName
//        {
//            get => state.AppName.Value;
//            set
//            {
//                state.AppName.Value = value;
//                PropertyChanged(this, new PropertyChangedEventArgs(nameof(AppName)));
//            }
//        }

//        public string AppDomain
//        {
//            get => state.AppDomain.Value;
//            set
//            {
//                state.AppDomain.Value = value;
//                PropertyChanged(this, new PropertyChangedEventArgs(nameof(AppDomain)));
//            }
//        }

//        public string Admin
//        {
//            get => state.Admin.Value;
//            set
//            {
//                state.Admin.Value = value;
//                PropertyChanged(this, new PropertyChangedEventArgs(nameof(Admin)));
//            }
//        }
//    }
//}
