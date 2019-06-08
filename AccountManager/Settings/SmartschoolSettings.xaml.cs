using AbstractAccountApi;
using AccountApi;
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
    /// Interaction logic for SmartschoolSettings.xaml
    /// </summary>
    public partial class SmartschoolSettings : UserControl
    {
        public Prop<bool> ShowConnectButtonIndicator { get; set; } = new Prop<bool> { Value = false };
        public Prop<bool> ShowSchoolReloadButtonIndicator { get; set; } = new Prop<bool> { Value = false };

        PackIcon ConnectButtonIcon;

        public Data Data { get => Data.Instance; }

        private Dialogs.ImportRuleSelectDialog importRuleSelectDialog;
        private Dialogs.IRuleEditor importRuleEditor;

        public SmartschoolSettings()
        {
            InitializeComponent();
            MainGrid.DataContext = this;
        }

        private void ConnectButtonIconControl_Loaded(object sender, RoutedEventArgs e)
        {
            // the icon is inside a data template, so we need a reference to change it later
            ConnectButtonIcon = sender as PackIcon;
        }

        private async void TestConnectButton_Click(object sender, RoutedEventArgs e)
        {
            Data.Instance.SetSmartschoolCredentials();
            ShowConnectButtonIndicator.Value = true;
            await TestSmartschoolConnection();
            ShowConnectButtonIndicator.Value = false;
        }

        private async Task TestSmartschoolConnection()
        {
            bool result = await Data.Instance.TestSmartschoolConnection();
            if (!result) ConnectButtonIcon.Kind = PackIconKind.CloudOffOutline;
            else ConnectButtonIcon.Kind = PackIconKind.CloudTick;
        }

        private async void AddRuleButton_Click(object sender, RoutedEventArgs e)
        {
            importRuleSelectDialog = new Dialogs.ImportRuleSelectDialog(AccountApi.RuleType.SS_Import);
            await DialogHost.Show(
                importRuleSelectDialog, 
                "RootDialog", 
                CloseAddRuleEventHandler
            );
            
        }

        private void CloseAddRuleEventHandler(object sender, DialogClosingEventArgs eventArgs)
        {
            var result = eventArgs.Parameter as string;
            if(result == "true")
            {
                var rule = Data.Instance.AddSmartschoolImportRule(importRuleSelectDialog.SelectedRule);
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
                case Rule.SS_DiscardGroup: importRuleEditor = new Dialogs.SS_DiscardGroupEditor(rule); break;
                case Rule.SS_NoSubGroups: importRuleEditor = new Dialogs.SS_DiscardSubGroupEditor(rule); break;
            }
            if (importRuleEditor != null)
            {
                await DialogHost.Show(
                    importRuleEditor,
                    "RootDialog",
                    CloseEditRuleEventHandler
                );
            }
        }

        private void CloseEditRuleEventHandler(object sender, DialogClosingEventArgs eventArgs)
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
