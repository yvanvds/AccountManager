using AbstractAccountApi;
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

        private Dialogs.ImportRuleSelectDialog importRuleSelectDialog;
        private Dialogs.IRuleEditor importRuleEditor;

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

        private async void AddRuleButton_Click(object sender, RoutedEventArgs e)
        {
            importRuleSelectDialog = new Dialogs.ImportRuleSelectDialog(AbstractAccountApi.RuleType.WISA_Import);
            await DialogHost.Show(
                importRuleSelectDialog,
                "RootDialog",
                closeAddRuleEventHandler
            );
        }

        private void closeAddRuleEventHandler(object sender, DialogClosingEventArgs eventArgs)
        {
            var result = eventArgs.Parameter as string;
            if (result == "true")
            {
                var rule = Data.Instance.AddWisaImportRule(importRuleSelectDialog.SelectedRule);
                eventArgs.Handled = true;
            }
        }

        private async void RuleEditButton_Click(object sender, RoutedEventArgs e)
        {
            var rule = (e.Source as Button).DataContext as IRule;
            await OpenRuleEditor(rule);
        }

        private async Task OpenRuleEditor(IRule rule)
        {
            importRuleEditor = null;
            switch (rule.Rule)
            {
                case Rule.WI_ReplaceInstitution: importRuleEditor = new Dialogs.WI_ReplaceInstitute(rule); break;
                case Rule.WI_DontImportClass: importRuleEditor = new Dialogs.WI_DontImportClass(rule); break;
            }
            if (importRuleEditor != null)
            {
                await DialogHost.Show(
                    importRuleEditor,
                    "RootDialog",
                    closeEditRuleEventHandler
                );
            }
        }

        private void closeEditRuleEventHandler(object sender, DialogClosingEventArgs eventArgs)
        {
            var result = eventArgs.Parameter as string;
            if (result.Equals("true", StringComparison.CurrentCultureIgnoreCase))
            {
                Data.Instance.ConfigChanged = true;
            }
        }

        private void RuleDeleteButton_Click(object sender, RoutedEventArgs e)
        {
            var rule = (e.Source as Button).DataContext as IRule;
            Data.Instance.SmartschoolImportRules.Remove(rule);
            Data.Instance.ConfigChanged = true;
        }
    }
}
