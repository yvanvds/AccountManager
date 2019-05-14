using MaterialDesignThemes.Wpf;
using System;
using System.Collections.Generic;
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

namespace AccountManager.Settings
{
    /// <summary>
    /// Interaction logic for WisaSettings.xaml
    /// </summary>
    public partial class WisaSettings : UserControl
    {
        public bool ShowConnectButtonIndicator { get; set; } = false;

        PackIcon ConnectButtonIcon;

        public Data Data { get => Data.Instance; }

        public WisaSettings()
        {
            InitializeComponent();
            MainGrid.DataContext = this;
        }

        private async void TestConnectButton_Click(object sender, RoutedEventArgs e) 
        {
            
            Data.Instance.SetWisaCredentials();
            var button = sender as Button;
            ShowConnectButtonIndicator = true;
            button.GetBindingExpression(ButtonProgressAssist.IsIndicatorVisibleProperty).UpdateSource();
            bool result = await WisaApi.Connector.TestConnection();
            if (!result) ConnectButtonIcon.Kind = PackIconKind.CloudOffOutline;
            else ConnectButtonIcon.Kind = PackIconKind.CloudTick;
            //ShowConnectButtonIndicator = false;
        }

        private void ConnectButtonIconControl_Loaded(object sender, RoutedEventArgs e)
        {
            ConnectButtonIcon = sender as PackIcon;
        }
    }
}
