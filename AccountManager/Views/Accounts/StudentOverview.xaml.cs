using AccountManager.Action;
using MaterialDesignThemes.Wpf;
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using static AbstractAccountApi.ObservableProperties;

namespace AccountManager.Views.Accounts
{
    /// <summary>
    /// Interaction logic for Overview.xaml
    /// </summary>
    public partial class StudentOverview : UserControl
    {
        
        public Prop<bool> Working { get; set; } = new Prop<bool>() { Value = false };


        public StudentOverview()
        {
            InitializeComponent();
            
            DataContext = new ViewModels.Accounts.StudentOverview();
        }

        //private async void ActionButton_Click(object sender, RoutedEventArgs e)
        //{
        //    ButtonProgressAssist.SetIsIndicatorVisible((e.Source as DependencyObject), true);
        //    AccountAction action = (e.Source as Button).DataContext as AccountAction;
        //    if(action.CanBeAppliedToAll && action.ApplyToAll.Value)
        //    {
        //        var items = AccountList.ItemsSource;
        //        foreach(var item in items)
        //        {
        //            var account = item as State.Linked.Account;
        //            var sameAction = account.GetSameAction(action);
        //            if(sameAction != null)
        //            {
        //                await sameAction.Apply(account, StudentDeleteDate);
                        
        //            }
                    
        //        }
        //        MainWindow.Instance.Log.AddMessage(AccountApi.Origin.Other, "Alle Acties werden uitgevoerd.");
        //    } else
        //    {
        //        await action.Apply(SelectedAccount.Value, StudentDeleteDate);
        //    }
                        
        //    await State.App.Instance.Linked.Accounts.ReLink();
        //    await CreateCollection();
        //    ButtonProgressAssist.SetIsIndicatorVisible((e.Source as DependencyObject), true);
        //}
    }
}
