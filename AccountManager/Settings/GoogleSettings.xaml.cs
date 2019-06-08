using MaterialDesignThemes.Wpf;
using Microsoft.Win32;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Navigation;
using System.Windows.Shapes;
using static AbstractAccountApi.ObservableProperties;

namespace AccountManager.Settings
{
    /// <summary>
    /// Interaction logic for GoogleSettings.xaml
    /// </summary>
    public partial class GoogleSettings : UserControl
    {
        public Prop<bool> ShowConnectButtonIndicator { get; set; } = new Prop<bool> { Value = false };
        public Prop<string> SecretStatus { get; set; } = new Prop<string> { Value = "not set"};

        PackIcon ConnectButtonIcon;

        public Data Data { get => Data.Instance; }

        public GoogleSettings()
        {
            InitializeComponent();
            MainGrid.DataContext = this;
            if(Data.IsGoogleSecretSet)
            {
                SecretStatus.Value = "Secret is Set";
            } else
            {
                SecretStatus.Value = "Secret is not Set";
            }
        }

        private void TestConnectButton_Click(object sender, RoutedEventArgs e)
        {
            ShowConnectButtonIndicator.Value = true;
            Data.Instance.SetGoogleCredentials();
            if(Data.Instance.GoogleConnectionTested == AccountApi.ConfigState.OK)
            {
                ConnectButtonIcon.Kind = PackIconKind.CloudTick;
            } else
            {
                ConnectButtonIcon.Kind = PackIconKind.CloudOffOutline;
            }
            ShowConnectButtonIndicator.Value = false;
        }

        private void ConnectButtonIconControl_Loaded(object sender, RoutedEventArgs e)
        {
            ConnectButtonIcon = sender as PackIcon;
        }

        private void OpenFile_Click(object sender, RoutedEventArgs e)
        {
            OpenFileDialog openFileDialog = new OpenFileDialog
            {
                Filter = "Json Files (*.json)|*.json|All Files (*.*)|*.*"
            };
            if (openFileDialog.ShowDialog() == true)
            {
                string content = File.ReadAllText(openFileDialog.FileName);
                Data.SetGoogleSecret(content);
                SecretStatus.Value = "Secret is Set";
            }
        }
    }
}
