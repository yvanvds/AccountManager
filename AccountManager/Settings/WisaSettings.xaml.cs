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
using static AbstractAccountApi.ObservableProperties;

namespace AccountManager.Settings
{
    /// <summary>
    /// Interaction logic for WisaSettings.xaml
    /// </summary>
    public partial class WisaSettings : UserControl
    {
        public Prop<bool> ShowConnectButtonIndicator { get; set; } = new Prop<bool> { Value = false };
        public Prop<bool> ShowSchoolReloadButtonIndicator { get; set; } = new Prop<bool> { Value = false };

        PackIcon ConnectButtonIcon;

        public Data Data { get => Data.Instance; }

        public WisaSettings()
        {
            InitializeComponent();
            MainGrid.DataContext = this;
            testWisaConnection();
            SchoolList.ItemsSource = WisaApi.Schools.All;
        }

        private async void TestConnectButton_Click(object sender, RoutedEventArgs e) 
        {
            
            Data.Instance.SetWisaCredentials();
            ShowConnectButtonIndicator.Value = true;
            await testWisaConnection();
            ShowConnectButtonIndicator.Value = false;
        }

        private void ConnectButtonIconControl_Loaded(object sender, RoutedEventArgs e)
        {
            // the icon is inside a data template, so we need a reference to change it later
            ConnectButtonIcon = sender as PackIcon;
        }

        private async Task testWisaConnection()
        {
            bool result = await WisaApi.Connector.TestConnection();
            if (!result) ConnectButtonIcon.Kind = PackIconKind.CloudOffOutline;
            else ConnectButtonIcon.Kind = PackIconKind.CloudTick;
        }

        private async void ReloadSchoolsButton_Click(object sender, RoutedEventArgs e)
        {
            ShowSchoolReloadButtonIndicator.Value = true;
            Data.Instance.SetWisaCredentials();
            await Data.Instance.ReloadWisaSchools();
            ShowSchoolReloadButtonIndicator.Value = false;
        }

        private void SelectSchoolButton_Click(object sender, RoutedEventArgs e)
        {
            Data.Instance.saveWisaSchoolsToJSON();
        }
    }
}
